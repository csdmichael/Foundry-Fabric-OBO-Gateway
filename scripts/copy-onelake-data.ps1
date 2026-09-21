[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [ValidateRange(1, 32)]
    [int] $ThrottleLimit = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$sourceTenantId = Assert-FabricGuid -Value $config.migration.sourceTenantId -Name 'migration.sourceTenantId'
$sourceSubscriptionId = Assert-FabricGuid -Value $config.migration.sourceSubscriptionId -Name 'migration.sourceSubscriptionId'
$sourceWorkspaceId = Assert-FabricGuid -Value $config.migration.sourceWorkspaceId -Name 'migration.sourceWorkspaceId'
$sourceLakehouseId = Assert-FabricGuid -Value $config.migration.sourceLakehouseId -Name 'migration.sourceLakehouseId'
$targetTenantId = Assert-FabricGuid -Value $config.azure.tenantId -Name 'azure.tenantId'
$targetSubscriptionId = Assert-FabricGuid -Value $config.azure.subscriptionId -Name 'azure.subscriptionId'
$targetWorkspaceId = Assert-FabricGuid -Value $config.fabric.workspaceId -Name 'fabric.workspaceId'
$targetLakehouseId = Assert-FabricGuid -Value $config.fabric.lakehouseId -Name 'fabric.lakehouseId'

$sourceToken = Get-FabricAzAccessToken -TenantId $sourceTenantId -SubscriptionId $sourceSubscriptionId -Resource 'https://storage.azure.com/'
$targetToken = Get-FabricAzAccessToken -TenantId $targetTenantId -SubscriptionId $targetSubscriptionId -Resource 'https://storage.azure.com/'

function ConvertTo-OneLakePath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    return (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

try {
    $headers = @{
        Authorization = "Bearer $sourceToken"
        'x-ms-version' = '2023-11-03'
    }
    $listBaseUri = "https://onelake.dfs.fabric.microsoft.com/${sourceWorkspaceId}?resource=filesystem&directory=${sourceLakehouseId}&recursive=true&maxResults=5000"
    $paths = [System.Collections.Generic.List[object]]::new()
    $continuation = ''

    do {
        $listUri = $listBaseUri
        if (-not [string]::IsNullOrWhiteSpace($continuation)) {
            $listUri += "&continuation=$([uri]::EscapeDataString($continuation))"
        }
        $response = Invoke-WebRequest -Headers $headers -Uri $listUri
        $payload = $response.Content | ConvertFrom-Json
        foreach ($path in @($payload.paths)) {
            if (-not $path.PSObject.Properties['isDirectory'] -or $path.isDirectory -ne 'true') {
                $paths.Add($path)
            }
        }
        $continuation = if ($response.Headers.ContainsKey('x-ms-continuation')) {
            $response.Headers['x-ms-continuation'] -join ''
        }
        else {
            ''
        }
    } while (-not [string]::IsNullOrWhiteSpace($continuation))

    $sourcePrefixLength = $sourceLakehouseId.Length + 1
    $copyResults = @($paths | ForEach-Object -Parallel {
        $path = $_
        $relativePath = $path.name.Substring($using:sourcePrefixLength)
        $encodedPath = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $sourceUri = "https://onelake.blob.fabric.microsoft.com/$using:sourceWorkspaceId/$using:sourceLakehouseId/$encodedPath"
        $targetUri = "https://onelake.blob.fabric.microsoft.com/$using:targetWorkspaceId/$using:targetLakehouseId/$encodedPath"

        try {
            $download = Invoke-WebRequest -Headers @{
                Authorization = "Bearer $using:sourceToken"
                'x-ms-version' = '2023-11-03'
            } -Uri $sourceUri -SkipHttpErrorCheck
            if ([int]$download.StatusCode -ne 200) {
                throw "Source returned HTTP $([int]$download.StatusCode)."
            }

            $upload = Invoke-WebRequest -Method Put -Headers @{
                Authorization = "Bearer $using:targetToken"
                'x-ms-version' = '2023-11-03'
                'x-ms-blob-type' = 'BlockBlob'
            } -Uri $targetUri -ContentType 'application/octet-stream' -Body $download.RawContentStream.ToArray() -SkipHttpErrorCheck
            if ([int]$upload.StatusCode -notin @(200, 201)) {
                throw "Target returned HTTP $([int]$upload.StatusCode): $($upload.Content)"
            }

            [pscustomobject]@{
                Path = $relativePath
                Bytes = [long]$path.contentLength
                Succeeded = $true
                Error = $null
            }
        }
        catch {
            [pscustomobject]@{
                Path = $relativePath
                Bytes = [long]$path.contentLength
                Succeeded = $false
                Error = $_.Exception.Message
            }
        }
    } -ThrottleLimit $ThrottleLimit)

    $failures = @($copyResults | Where-Object { -not $_.Succeeded })
    if ($failures.Count -gt 0) {
        $sample = @($failures | Select-Object -First 10 | ForEach-Object { "$($_.Path): $($_.Error)" })
        throw "OneLake copy failed for $($failures.Count) file(s): $($sample -join '; ')"
    }

    $expectedBytes = [long](($paths | Measure-Object -Property contentLength -Sum).Sum)
    $copiedBytes = [long](($copyResults | Measure-Object -Property Bytes -Sum).Sum)
    if ($copiedBytes -ne $expectedBytes) {
        throw "OneLake byte-count mismatch. Expected $expectedBytes bytes and copied $copiedBytes bytes."
    }

    [pscustomobject]@{
        SourceWorkspaceId = $sourceWorkspaceId
        SourceLakehouseId = $sourceLakehouseId
        TargetWorkspaceId = $targetWorkspaceId
        TargetLakehouseId = $targetLakehouseId
        FileCount = $copyResults.Count
        BytesCopied = $copiedBytes
    }
}
finally {
    $sourceToken = $null
    $targetToken = $null
    $headers = $null
}