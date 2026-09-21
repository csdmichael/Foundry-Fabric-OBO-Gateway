[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../.generated/foundry-iq/parts-shortages')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$tenantId = Assert-FabricGuid -Value $config.azure.tenantId -Name 'azure.tenantId'
$subscriptionId = Assert-FabricGuid -Value $config.azure.subscriptionId -Name 'azure.subscriptionId'
$workspaceId = Assert-FabricGuid -Value $config.fabric.workspaceId -Name 'fabric.workspaceId'
$lakehouseId = Assert-FabricGuid -Value $config.fabric.lakehouseId -Name 'fabric.lakehouseId'
$sqlEndpointHost = [string]$config.fabric.sqlEndpointHost
$lakehouseName = [string]$config.fabric.lakehouseName
$knowledge = $config.foundry.knowledgeBases.lakehouse
$snapshotPath = ([string]$knowledge.snapshotPath).Trim('/')
$batchSize = [int]$knowledge.batchSize

if ($sqlEndpointHost -notmatch '^[a-z0-9-]+\.datawarehouse\.fabric\.microsoft\.com$') {
    throw 'fabric.sqlEndpointHost is not a Microsoft Fabric SQL endpoint host.'
}
if ([string]::IsNullOrWhiteSpace($snapshotPath) -or -not $snapshotPath.StartsWith('Files/')) {
    throw 'foundry.knowledgeBases.lakehouse.snapshotPath must be under Files/.'
}
if ($batchSize -lt 25 -or $batchSize -gt 500) {
    throw 'foundry.knowledgeBases.lakehouse.batchSize must be between 25 and 500.'
}

function ConvertTo-OneLakePath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    return (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function ConvertTo-KnowledgeCell {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value -or $Value -is [DBNull]) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return $Value.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ').Trim()
}

function Write-KnowledgeFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string[]] $Lines
    )

    $content = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}

function Put-OneLakeFile {
    param(
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [byte[]] $Content,
        [Parameter(Mandatory = $true)] [string] $AccessToken
    )

    $encodedPath = ConvertTo-OneLakePath -Path $RelativePath
    $uri = "https://onelake.blob.fabric.microsoft.com/$workspaceId/$lakehouseId/$encodedPath"
    $response = Invoke-WebRequest -Method Put -Uri $uri -Headers @{
        Authorization = "Bearer $AccessToken"
        'x-ms-version' = '2023-11-03'
        'x-ms-blob-type' = 'BlockBlob'
    } -ContentType 'text/markdown; charset=utf-8' -Body $Content -SkipHttpErrorCheck
    if ([int]$response.StatusCode -notin @(200, 201)) {
        throw "OneLake upload failed for '$RelativePath': HTTP $([int]$response.StatusCode) $($response.Content)"
    }
}

function Get-OneLakeFiles {
    param([Parameter(Mandatory = $true)] [string] $AccessToken)

    $directory = ConvertTo-OneLakePath -Path "$lakehouseId/$snapshotPath"
    $uri = "https://onelake.dfs.fabric.microsoft.com/${workspaceId}?resource=filesystem&directory=$directory&recursive=true&maxResults=5000"
    $response = Invoke-WebRequest -Uri $uri -Headers @{
        Authorization = "Bearer $AccessToken"
        'x-ms-version' = '2023-11-03'
    } -SkipHttpErrorCheck
    if ([int]$response.StatusCode -eq 404) { return @() }
    if ([int]$response.StatusCode -ne 200) {
        throw "Unable to list OneLake knowledge files: HTTP $([int]$response.StatusCode) $($response.Content)"
    }
    return @((($response.Content | ConvertFrom-Json).paths) | Where-Object {
        -not $_.PSObject.Properties['isDirectory'] -or $_.isDirectory -ne 'true'
    })
}

function Remove-OneLakeFile {
    param(
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [string] $AccessToken
    )

    $encodedPath = ConvertTo-OneLakePath -Path $RelativePath
    $uri = "https://onelake.blob.fabric.microsoft.com/$workspaceId/$lakehouseId/$encodedPath"
    $response = Invoke-WebRequest -Method Delete -Uri $uri -Headers @{
        Authorization = "Bearer $AccessToken"
        'x-ms-version' = '2023-11-03'
        'If-Match' = '*'
    } -SkipHttpErrorCheck
    if ([int]$response.StatusCode -notin @(202, 204, 404)) {
        throw "Unable to delete stale OneLake knowledge file '$RelativePath': HTTP $([int]$response.StatusCode) $($response.Content)"
    }
}

$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $resolvedOutput) { Remove-Item -LiteralPath $resolvedOutput -Recurse -Force }
$null = New-Item -ItemType Directory -Path $resolvedOutput -Force

$sqlToken = Get-FabricAzAccessToken -TenantId $tenantId -SubscriptionId $subscriptionId -Resource 'https://database.windows.net/'
$rows = [System.Collections.Generic.List[object]]::new()
$generatedAt = [datetime]::UtcNow
Add-Type -AssemblyName System.Data
$connection = [System.Data.SqlClient.SqlConnection]::new("Server=tcp:$sqlEndpointHost,1433;Initial Catalog=$lakehouseName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
$connection.AccessToken = $sqlToken
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 180
    $command.CommandText = @'
SELECT shortage_id, matnr, material_text, plant, supplier_code, supplier_name,
       severity_band, qty_short, gap_qty, days_until_need, need_date,
       expected_delivery_date, logged_at, last_modified_at, status,
       ml_risk_score, ml_risk_band, ml_recommended_path,
       ml_expected_impact_usd, ml_rationale
FROM bv.vw_part_shortage_360
WHERE UPPER(LTRIM(RTRIM(status))) = 'OPEN'
ORDER BY CASE UPPER(severity_band) WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END,
         need_date, matnr, shortage_id
'@
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                $row[$reader.GetName($index)] = $reader.GetValue($index)
            }
            $rows.Add([pscustomobject]$row)
        }
    }
    finally { $reader.Dispose() }
}
finally {
    $connection.Dispose()
    $sqlToken = $null
}

if ($rows.Count -eq 0) { throw 'The live shortage view returned no OPEN rows; refusing to publish an empty knowledge snapshot.' }

$columns = [ordered]@{
    shortage_id = 'Shortage ID'
    matnr = 'Part Number'
    material_text = 'Material'
    plant = 'Plant'
    supplier_code = 'Supplier Code'
    supplier_name = 'Supplier'
    severity_band = 'Severity'
    qty_short = 'Shortage Quantity'
    gap_qty = 'Gap Quantity'
    days_until_need = 'Days Until Need'
    need_date = 'Need Date'
    expected_delivery_date = 'Expected Delivery Date'
    logged_at = 'Logged At'
    last_modified_at = 'Last Modified At'
    status = 'Status'
    ml_risk_score = 'ML Risk Score'
    ml_risk_band = 'ML Risk Band'
    ml_recommended_path = 'ML Recommended Path'
    ml_expected_impact_usd = 'ML Expected Impact USD'
    ml_rationale = 'ML Rationale'
}

$generatedFiles = [System.Collections.Generic.List[object]]::new()
$batchCount = [math]::Ceiling($rows.Count / $batchSize)
for ($batch = 0; $batch -lt $batchCount; $batch++) {
    $start = $batch * $batchSize
    $end = [math]::Min($start + $batchSize, $rows.Count)
    $fileName = 'open-shortages-{0:D4}.md' -f ($batch + 1)
    $filePath = Join-Path $resolvedOutput $fileName
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Open Parts Shortages Snapshot')
    $lines.Add('')
    $lines.Add("- Generated UTC: $($generatedAt.ToString('o'))")
    $lines.Add('- Source: `lh_part_shortages_v2.bv.vw_part_shortage_360`')
    $lines.Add('- Filter: live records where `status = OPEN`')
    $lines.Add("- Snapshot rows in this file: $($start + 1)-$end of $($rows.Count)")
    $lines.Add('')
    $lines.Add('| ' + (($columns.Values | ForEach-Object { $_ }) -join ' | ') + ' |')
    $lines.Add('| ' + (($columns.Values | ForEach-Object { '---' }) -join ' | ') + ' |')
    for ($rowIndex = $start; $rowIndex -lt $end; $rowIndex++) {
        $row = $rows[$rowIndex]
        $values = @($columns.Keys | ForEach-Object { ConvertTo-KnowledgeCell -Value $row.$_ })
        $lines.Add('| ' + ($values -join ' | ') + ' |')
    }
    Write-KnowledgeFile -Path $filePath -Lines $lines
    $generatedFiles.Add([pscustomobject]@{
        Name = $fileName
        Path = $filePath
        RelativePath = "$snapshotPath/$fileName"
        Sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Bytes = (Get-Item -LiteralPath $filePath).Length
    })
}

$manifestName = 'snapshot-manifest.md'
$manifestPath = Join-Path $resolvedOutput $manifestName
$manifestLines = [System.Collections.Generic.List[string]]::new()
$manifestLines.Add('# Parts Shortages Knowledge Snapshot Manifest')
$manifestLines.Add('')
$manifestLines.Add("- Generated UTC: $($generatedAt.ToString('o'))")
$manifestLines.Add('- Source: `lh_part_shortages_v2.bv.vw_part_shortage_360`')
$manifestLines.Add('- Filter: live records where `status = OPEN`')
$manifestLines.Add("- Open row count: $($rows.Count)")
$manifestLines.Add("- Batch size: $batchSize")
$manifestLines.Add("- Batch count: $batchCount")
$manifestLines.Add('')
$manifestLines.Add('| File | SHA-256 | Bytes |')
$manifestLines.Add('| --- | --- | ---: |')
foreach ($file in $generatedFiles) { $manifestLines.Add("| $($file.Name) | `$($file.Sha256)` | $($file.Bytes) |") }
Write-KnowledgeFile -Path $manifestPath -Lines $manifestLines
$generatedFiles.Add([pscustomobject]@{
    Name = $manifestName
    Path = $manifestPath
    RelativePath = "$snapshotPath/$manifestName"
    Sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Bytes = (Get-Item -LiteralPath $manifestPath).Length
})

$storageToken = Get-FabricAzAccessToken -TenantId $tenantId -SubscriptionId $subscriptionId -Resource 'https://storage.azure.com/'
try {
    foreach ($file in $generatedFiles) {
        Put-OneLakeFile -RelativePath $file.RelativePath -Content ([IO.File]::ReadAllBytes($file.Path)) -AccessToken $storageToken
    }

    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $generatedFiles) { $null = $expected.Add($file.RelativePath) }
    foreach ($remoteFile in @(Get-OneLakeFiles -AccessToken $storageToken)) {
        $relativePath = ([string]$remoteFile.name).Substring($lakehouseId.Length + 1)
        if (-not $expected.Contains($relativePath)) {
            Remove-OneLakeFile -RelativePath $relativePath -AccessToken $storageToken
        }
    }
}
finally { $storageToken = $null }

$searchKey = az search admin-key show --service-name ([string]$knowledge.searchServiceName) --resource-group $config.azure.resourceGroup --subscription $subscriptionId --query primaryKey -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($searchKey)) { throw 'Unable to retrieve the Azure AI Search admin key for synchronization.' }
$syncState = 'requested'
try {
    $syncUri = "$([string]$knowledge.searchEndpoint)/knowledgesources/$([string]$knowledge.knowledgeSourceName)/synchronize?api-version=2026-08-01-preview"
    $syncResponse = Invoke-WebRequest -Method Post -Uri $syncUri -Headers @{'api-key' = $searchKey} -SkipHttpErrorCheck
    if ([int]$syncResponse.StatusCode -eq 409) { $syncState = 'already-active' }
    elseif ([int]$syncResponse.StatusCode -notin @(200, 202, 204)) {
        throw "Foundry IQ synchronization request failed: HTTP $([int]$syncResponse.StatusCode) $($syncResponse.Content)"
    }
}
finally { $searchKey = $null }

$checkpoint = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = $generatedAt.ToString('o')
    workspaceId = $workspaceId
    lakehouseId = $lakehouseId
    source = 'bv.vw_part_shortage_360'
    filter = 'status = OPEN'
    rowCount = $rows.Count
    batchCount = $batchCount
    snapshotPath = $snapshotPath
    synchronization = $syncState
    files = @($generatedFiles | ForEach-Object { [ordered]@{ name = $_.Name; sha256 = $_.Sha256; bytes = $_.Bytes } })
}
$checkpointPath = Join-Path $resolvedOutput 'checkpoint.json'
[IO.File]::WriteAllText($checkpointPath, (($checkpoint | ConvertTo-Json -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
$checkpoint | ConvertTo-Json -Depth 6