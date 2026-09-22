[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../.generated/agents'),
    [switch] $Import,
    [switch] $Publish
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
if ($Import -or $Publish) {
    throw 'Cloud agent mutation is intentionally disabled in package-agents.ps1. Use this script to build source artifacts, then create/import, bind tools, verify OAuth connections and code interpreter, and publish through Copilot Studio with captured evidence.'
}
$publisherPrefix = [string](Get-FabricConfigValue -Config $config -Path 'powerPlatform.publisherPrefix')
$fabricRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)

if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw 'Power Platform CLI is required. Install Microsoft.PowerApps.CLI.Tool first.'
}

New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$agents = @(
    [pscustomobject]@{
        ProjectDirectory = Join-Path $fabricRoot 'agents/lakehouse'
        SchemaName = [string]$config.powerPlatform.lakehouseAgentSchemaName
        SolutionName = [string]$config.powerPlatform.lakehouseAgentSolutionName
        ConnectorName = [string]$config.powerPlatform.lakehouseConnectorName
        PromptName = [string]$config.powerPlatform.lakehouseDeckPromptName
        InstructionMarker = 'Search open Lakehouse shortages tool'
    },
    [pscustomobject]@{
        ProjectDirectory = Join-Path $fabricRoot 'agents/data-agent'
        SchemaName = [string]$config.powerPlatform.dataAgentAgentSchemaName
        SolutionName = [string]$config.powerPlatform.dataAgentAgentSolutionName
        ConnectorName = [string]$config.powerPlatform.dataAgentConnectorName
        PromptName = [string]$config.powerPlatform.dataAgentDeckPromptName
        InstructionMarker = 'Fabric Data Agent tool for every business-data question'
    }
)

foreach ($agent in $agents) {
    Get-ChildItem -Path $resolvedOutput -Filter "$($agent.SolutionName)*.zip" -File -ErrorAction SilentlyContinue | Remove-Item -Force
    pac copilot pack --publisher-prefix $publisherPrefix --project-dir $agent.ProjectDirectory --solution-name $agent.SolutionName --output-path $resolvedOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to package agent '$($agent.SchemaName)'."
    }
}

$packages = @()
foreach ($agent in $agents) {
    $candidatePackages = @(Get-ChildItem -Path $resolvedOutput -Filter "$($agent.SolutionName)*.zip" | Sort-Object LastWriteTimeUtc -Descending)
    if ($candidatePackages.Count -eq 0) {
        throw "Package output was not found for '$($agent.SolutionName)'."
    }
    $packages += [pscustomobject]@{ Agent = $agent; Package = $candidatePackages[0] }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($entry in $packages) {
    $archive = [IO.Compression.ZipFile]::OpenRead($entry.Package.FullName)
    try {
        $botEntry = $archive.GetEntry("bots/$($entry.Agent.SchemaName)/bot.xml")
        $configurationEntry = $archive.GetEntry("bots/$($entry.Agent.SchemaName)/configuration.json")
        if (-not $botEntry -or -not $configurationEntry) {
            throw "Package '$($entry.Agent.SolutionName)' is missing its bot metadata."
        }
        $reader = [IO.StreamReader]::new($botEntry.Open())
        try { $botXml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        if ([string]$botXml.bot.language -ne '1033') {
            throw "Package '$($entry.Agent.SolutionName)' has invalid bot language '$($botXml.bot.language)'."
        }
        $reader = [IO.StreamReader]::new($configurationEntry.Open())
        try { $configuration = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if (-not $configuration.Contains($entry.Agent.InstructionMarker)) {
            throw "Package '$($entry.Agent.SolutionName)' did not serialize its agent instructions."
        }
    }
    finally {
        $archive.Dispose()
    }
}

$packageEvidence = @{}
foreach ($entry in $packages) {
    $packageEvidence[$entry.Agent.SchemaName] = Get-FabricAgentPackageEvidence `
        -PackagePath $entry.Package.FullName `
        -SchemaName $entry.Agent.SchemaName `
        -ConnectorName $entry.Agent.ConnectorName `
        -PromptName $entry.Agent.PromptName
}

$packages | ForEach-Object {
    $evidence = $packageEvidence[$_.Agent.SchemaName]
    [pscustomobject]@{
        SchemaName = $_.Agent.SchemaName
        SolutionName = $_.Agent.SolutionName
        PackagePath = $_.Package.FullName
        BoundComponentCount = $evidence.BoundComponentCount
        ContainsExpectedConnectorText = $evidence.HasExpectedConnector
        ContainsExpectedPromptText = $evidence.HasExpectedPrompt
        ContainsConnectionReferenceText = $evidence.HasConnectionReference
        CloudMutationPerformed = $false
    }
}