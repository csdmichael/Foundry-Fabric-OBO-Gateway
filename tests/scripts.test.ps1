$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/config.ps1')
. (Join-Path $PSScriptRoot '../scripts/tokenomics-sync-contract.ps1')

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [Parameter(Mandatory = $true)] [string] $MessagePattern
    )

    $thrown = $false
    try {
        & $Action
    }
    catch {
        $thrown = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "Expected error matching '$MessagePattern', got '$($_.Exception.Message)'."
        }
    }
    if (-not $thrown) {
        throw "Expected an error matching '$MessagePattern'."
    }
}

$empty = Assert-FabricGuidList -Values @() -Name 'empty list' -AllowEmpty
if ($null -eq $empty -or $empty.Count -ne 0) {
    throw 'Empty GUID list was not preserved as an array.'
}
$single = Assert-FabricGuidList -Values @('11111111-1111-4111-8111-111111111111') -Name 'single list'
if ($single.Count -ne 1) {
    throw 'Single-item GUID list was not preserved as an array.'
}
Write-Host 'PASS StrictMode GUID list behavior'

$createChange = [pscustomobject]@{ changeType = 'Create'; resourceId = '/subscriptions/test/resourceGroups/test/providers/Test/type/name' }
$modifyChange = [pscustomobject]@{ changeType = 'Modify'; resourceId = '/subscriptions/test/resourceGroups/test/providers/Test/type/name' }
$deleteChange = [pscustomobject]@{ changeType = 'Delete'; resourceId = '/subscriptions/test/resourceGroups/test/providers/Test/type/name' }
$deployChange = [pscustomobject]@{ changeType = 'Deploy'; resourceId = '/subscriptions/test/resourceGroups/test/providers/Test/type/name' }
$futureChange = [pscustomobject]@{ changeType = 'FutureType'; resourceId = '/subscriptions/test/resourceGroups/test/providers/Test/type/name' }
$null = Assert-FabricWhatIfChanges -Changes @($createChange)
Assert-Throws -Action { Assert-FabricWhatIfChanges -Changes @($modifyChange) | Out-Null } -MessagePattern 'Modify'
$null = Assert-FabricWhatIfChanges -Changes @($modifyChange) -AllowModify
Assert-Throws -Action { Assert-FabricWhatIfChanges -Changes @($deleteChange) -AllowModify | Out-Null } -MessagePattern 'Delete'
Assert-Throws -Action { Assert-FabricWhatIfChanges -Changes @($deployChange) -AllowModify | Out-Null } -MessagePattern 'Deploy'
Assert-Throws -Action { Assert-FabricWhatIfChanges -Changes @($futureChange) -AllowModify | Out-Null } -MessagePattern 'FutureType'
Write-Host 'PASS Azure what-if safety policy'

$syncConfig = [pscustomobject]@{
    tokenomicsPlatform = [pscustomobject]@{
        fabric = [pscustomobject]@{
            workspaceName = 'Tokenomics Test'
            lakehouseName = 'lh_test'
            capacityId = '11111111-1111-4111-8111-111111111111'
        }
    }
}
$now = [DateTimeOffset]::Parse('2026-09-19T12:00:00Z')
$commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$fabricMetadata = [pscustomobject]@{
    configFingerprint = 'fingerprint'
    workspaceName = 'Tokenomics Test'
    lakehouseName = 'lh_test'
    capacityId = '11111111-1111-4111-8111-111111111111'
    workspaceId = '22222222-2222-4222-8222-222222222222'
    lakehouseId = '33333333-3333-4333-8333-333333333333'
}
$seedCheckpoint = [pscustomobject]@{
    configFingerprint = 'fingerprint'
    verifiedAt = '2026-09-19T11:30:00Z'
    repositoryCommit = $commit
    eventSetSha256 = ('b' * 64)
}
$null = Assert-TokenomicsSyncContract -Config $syncConfig -ConfigFingerprint 'fingerprint' -FabricMetadata $fabricMetadata -SeedCheckpoint $seedCheckpoint -RepositoryCommit $commit -CurrentTime $now -MaximumCheckpointAgeMinutes 120
$wrongTarget = $fabricMetadata.PSObject.Copy()
$wrongTarget.lakehouseName = 'lh_wrong'
Assert-Throws -Action {
    Assert-TokenomicsSyncContract -Config $syncConfig -ConfigFingerprint 'fingerprint' -FabricMetadata $wrongTarget -SeedCheckpoint $seedCheckpoint -RepositoryCommit $commit -CurrentTime $now -MaximumCheckpointAgeMinutes 120 | Out-Null
} -MessagePattern 'Fabric metadata does not match'
$staleCheckpoint = $seedCheckpoint.PSObject.Copy()
$staleCheckpoint.verifiedAt = '2026-09-19T08:00:00Z'
Assert-Throws -Action {
    Assert-TokenomicsSyncContract -Config $syncConfig -ConfigFingerprint 'fingerprint' -FabricMetadata $fabricMetadata -SeedCheckpoint $staleCheckpoint -RepositoryCommit $commit -CurrentTime $now -MaximumCheckpointAgeMinutes 120 | Out-Null
} -MessagePattern 'older than'
Assert-Throws -Action {
    Assert-TokenomicsSyncContract -Config $syncConfig -ConfigFingerprint 'fingerprint' -FabricMetadata $fabricMetadata -SeedCheckpoint $seedCheckpoint -RepositoryCommit ('c' * 40) -CurrentTime $now -MaximumCheckpointAgeMinutes 120 | Out-Null
} -MessagePattern 'current repository commit'
Write-Host 'PASS Tokenomics sync checkpoint safety policy'

$connectorScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../scripts/create-connectors.ps1') -Raw
if ($connectorScript -notmatch 'EnableOnbehalfOfLogin\s*=\s*@\{\s*value\s*=\s*\$true\s*\}' -or
    $connectorScript -match 'EnableOnbehalfOfLogin\s*=\s*@\{\s*value\s*=\s*\$false\s*\}') {
    throw 'Copilot Studio custom connectors must enable OBO login.'
}
Write-Host 'PASS Copilot Studio connector OBO contract'

$lakehouseSync = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../agents/lakehouse/deployment.binding.yaml') -Raw
$dataAgentSync = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../agents/data-agent/deployment.binding.yaml') -Raw
$lakehouseTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../agents/lakehouse/templates/private-lakehouse-knowledge.tool.mcs.yml') -Raw
$dataAgentTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../agents/data-agent/templates/private-data-agent-tool.tool.mcs.yml') -Raw
if ($lakehouseSync -notmatch 'kind:\s*connectorTool' -or $lakehouseSync -notmatch 'operationId:\s*knowledge' -or
    $lakehouseSync -notmatch 'connectionMode:\s*Invoker' -or $lakehouseTemplate -notmatch 'kind:\s*ConnectorTool' -or
    $lakehouseTemplate -notmatch 'operationId:\s*knowledge' -or $lakehouseTemplate -notmatch 'authMode:\s*Invoker') {
    throw 'Lakehouse Copilot Studio agent must use only the private OBO connector knowledge tool.'
}
if ($dataAgentSync -notmatch 'kind:\s*connectorTool' -or $dataAgentSync -notmatch 'operationId:\s*query' -or
    $dataAgentSync -notmatch 'connectionMode:\s*Invoker' -or $dataAgentTemplate -notmatch 'kind:\s*ConnectorTool' -or
    $dataAgentTemplate -notmatch 'operationId:\s*query' -or $dataAgentTemplate -notmatch 'authMode:\s*Invoker') {
    throw 'Data Agent Copilot Studio agent must use only the private OBO connector query tool.'
}
Write-Host 'PASS Copilot Studio agent binding contracts'

$testRoot = Join-Path $PSScriptRoot '../.generated/tests'
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
try {
    $zipStage = Join-Path $testRoot 'zip-stage'
    New-Item -ItemType Directory -Path (Join-Path $zipStage 'dist/src/functions') -Force | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $zipStage 'host.json') -Encoding utf8
    '{"name":"test"}' | Set-Content -LiteralPath (Join-Path $zipStage 'package.json') -Encoding utf8
    'export {};' | Set-Content -LiteralPath (Join-Path $zipStage 'dist/src/functions/http.js') -Encoding utf8
    $zipPath = Join-Path $testRoot 'portable.zip'
    $python = Get-Command python -ErrorAction Stop
    Invoke-FabricNative -FilePath $python.Source -ArgumentList @((Join-Path $PSScriptRoot '../scripts/create_zip.py'), $zipStage, $zipPath) -Description 'Portable ZIP test'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($archive.Entries.FullName)
        if ($names -notcontains 'dist/src/functions/http.js' -or $names | Where-Object { $_ -match '\\|^/|\.\./' }) {
            throw 'Portable ZIP test found invalid entry names.'
        }
    }
    finally {
        $archive.Dispose()
    }
    Write-Host 'PASS portable Function ZIP entries'

    function New-TestAgentPackage {
        param([string] $Path, [string] $SchemaName, [hashtable] $ExtraEntries)
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
        $testArchive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries = [ordered]@{
                "bots/$SchemaName/bot.xml" = '<bot />'
                "bots/$SchemaName/configuration.json" = '{}'
            }
            foreach ($key in $ExtraEntries.Keys) { $entries[$key] = $ExtraEntries[$key] }
            foreach ($key in $entries.Keys) {
                $zipEntry = $testArchive.CreateEntry($key)
                $writer = [System.IO.StreamWriter]::new($zipEntry.Open())
                try { $writer.Write([string]$entries[$key]) } finally { $writer.Dispose() }
            }
        }
        finally {
            $testArchive.Dispose()
            $stream.Dispose()
        }
    }

    $schemaName = 'test_agent'
    $connectorName = 'Expected Fabric Connector'
    $promptName = 'Expected Executive Deck Prompt'
    $emptyAgentPath = Join-Path $testRoot 'empty-agent.zip'
    New-TestAgentPackage -Path $emptyAgentPath -SchemaName $schemaName -ExtraEntries @{}
    $emptyEvidence = Get-FabricAgentPackageEvidence -PackagePath $emptyAgentPath -SchemaName $schemaName -ConnectorName $connectorName -PromptName $promptName
    if ($emptyEvidence.BoundComponentCount -ne 0 -or $emptyEvidence.HasExpectedConnector -or $emptyEvidence.HasExpectedPrompt -or $emptyEvidence.HasConnectionReference) { throw 'Agent-only fixture evidence was evaluated incorrectly.' }

    $partialAgentPath = Join-Path $testRoot 'partial-agent.zip'
    New-TestAgentPackage -Path $partialAgentPath -SchemaName $schemaName -ExtraEntries @{
        'actions/connector.xml' = "<action>$connectorName</action>"
    }
    $partialEvidence = Get-FabricAgentPackageEvidence -PackagePath $partialAgentPath -SchemaName $schemaName -ConnectorName $connectorName -PromptName $promptName
    if (-not $partialEvidence.HasExpectedConnector -or $partialEvidence.HasExpectedPrompt -or $partialEvidence.HasConnectionReference) {
        throw 'Partial agent fixture evidence was evaluated incorrectly.'
    }

    $completeAgentPath = Join-Path $testRoot 'complete-agent.zip'
    New-TestAgentPackage -Path $completeAgentPath -SchemaName $schemaName -ExtraEntries @{
        'actions/connector.xml' = "<action>$connectorName</action>"
        'prompts/deck.xml' = "<prompt>$promptName</prompt>"
        'connectionreferences/fabric.xml' = '<connectionReference />'
    }
    $completeEvidence = Get-FabricAgentPackageEvidence -PackagePath $completeAgentPath -SchemaName $schemaName -ConnectorName $connectorName -PromptName $promptName
    if ($completeEvidence.BoundComponentCount -lt 3 -or -not $completeEvidence.HasExpectedConnector -or -not $completeEvidence.HasExpectedPrompt -or -not $completeEvidence.HasConnectionReference) { throw 'Complete agent fixture evidence was evaluated incorrectly.' }
    Write-Host 'PASS exact agent package evidence'

    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if ($pac) {
        $config = Get-FabricDeploymentConfig -Path (Join-Path $PSScriptRoot '../config/deployment.json')
        $config.powerPlatform.environmentId = '77777777-7777-4777-8777-777777777777'
        $testConfigPath = Join-Path $testRoot 'deployment.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $testConfigPath -Encoding utf8
        $agentOutput = Join-Path $testRoot 'agents'
        Assert-Throws -Action {
            & (Join-Path $PSScriptRoot '../scripts/package-agents.ps1') -ConfigPath $testConfigPath -OutputDirectory $agentOutput -Publish | Out-Null
        } -MessagePattern 'Cloud agent mutation is intentionally disabled'
        Write-Host 'PASS automated agent mutation guard'
    }
    else {
        Write-Warning 'SKIP incomplete agent publication guard because PAC CLI is unavailable.'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Fabric deployment safety tests completed successfully.' -ForegroundColor Green
