[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $IdentityPath = (Join-Path $PSScriptRoot '../.generated/identity.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../.generated/copilot-studio/deployment.json'),
    [switch] $ProvisionConnectors,
    [switch] $ImportBaselines,
    [switch] $Publish
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$environmentId = Assert-FabricGuid -Value $config.powerPlatform.environmentId -Name 'powerPlatform.environmentId'
$environmentUrl = [string]$config.powerPlatform.environmentUrl
if ($environmentUrl -notmatch '^https://[a-z0-9-]+\.crm\d*\.dynamics\.com/?$') {
    throw 'powerPlatform.environmentUrl must be an HTTPS Dataverse environment URL.'
}
$environmentUrl = $environmentUrl.TrimEnd('/')
$repositoryRoot = Split-Path -Parent $PSScriptRoot

$agents = @(
    [pscustomobject]@{
        Kind = 'lakehouse'
        Directory = Join-Path $repositoryRoot 'agents/lakehouse'
        SchemaName = [string]$config.powerPlatform.lakehouseAgentSchemaName
        SolutionName = [string]$config.powerPlatform.lakehouseAgentSolutionName
        ConnectorName = [string]$config.powerPlatform.lakehouseConnectorName
        RequiredPatterns = @('OnKnowledgeRequested', 'operationId:\s*knowledge', 'System\.SearchResults', 'ConnectionReferenceBySchema')
    },
    [pscustomobject]@{
        Kind = 'dataAgent'
        Directory = Join-Path $repositoryRoot 'agents/data-agent'
        SchemaName = [string]$config.powerPlatform.dataAgentAgentSchemaName
        SolutionName = [string]$config.powerPlatform.dataAgentAgentSolutionName
        ConnectorName = [string]$config.powerPlatform.dataAgentConnectorName
        RequiredPatterns = @('InvokeConnectorTaskAction', 'operationId:\s*query', 'mode:\s*Invoker')
    }
)

function Assert-DesiredState {
    foreach ($agent in $agents) {
        $settingsPath = Join-Path $agent.Directory 'settings.mcs.yml'
        $bindingPath = Join-Path $agent.Directory 'deployment.binding.yaml'
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or -not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) {
            throw "Copilot Studio source is incomplete for '$($agent.Kind)'."
        }
        $settings = Get-Content -LiteralPath $settingsPath -Raw
        $binding = Get-Content -LiteralPath $bindingPath -Raw
        if ($settings -notmatch [regex]::Escape($agent.SchemaName) -or $binding -notmatch 'schemaVersion:\s*1' -or
            $binding -notmatch [regex]::Escape($agent.ConnectorName) -or $binding -notmatch 'connectionMode:\s*Invoker') {
            throw "Copilot Studio desired-state contract is invalid for '$($agent.Kind)'."
        }
    }

    $templatePath = Join-Path $agents[0].Directory 'templates/private-lakehouse-knowledge.topic.mcs.yml'
    $template = Get-Content -LiteralPath $templatePath -Raw
    foreach ($pattern in $agents[0].RequiredPatterns) {
        if ($template -notmatch $pattern) { throw "Lakehouse knowledge template is missing '$pattern'." }
    }
    $dataAgentTemplatePath = Join-Path $agents[1].Directory 'templates/private-data-agent-tool.action.mcs.yml'
    $dataAgentTemplate = Get-Content -LiteralPath $dataAgentTemplatePath -Raw
    foreach ($pattern in $agents[1].RequiredPatterns) {
        if ($dataAgentTemplate -notmatch $pattern) { throw "Data Agent tool template is missing '$pattern'." }
    }

    $definitions = @(& (Join-Path $PSScriptRoot 'create-connectors.ps1') -ConfigPath $ConfigPath -IdentityPath $IdentityPath -DefinitionOnly)
    $lakehouseDefinition = @($definitions | Where-Object Kind -eq 'lakehouse')
    $dataAgentDefinition = @($definitions | Where-Object Kind -eq 'dataAgent')
    if ($lakehouseDefinition.Count -ne 1 -or $dataAgentDefinition.Count -ne 1) {
        throw 'Exactly one Lakehouse and one Data Agent connector definition are required.'
    }
    $lakehouseSwagger = Get-Content -LiteralPath $lakehouseDefinition[0].DefinitionPath -Raw | ConvertFrom-Json
    $dataAgentSwagger = Get-Content -LiteralPath $dataAgentDefinition[0].DefinitionPath -Raw | ConvertFrom-Json
    if ($lakehouseSwagger.paths.'/knowledge'.post.operationId -ne 'knowledge' -or
        $dataAgentSwagger.paths.'/query'.post.operationId -ne 'query') {
        throw 'Copilot Studio connector definitions do not expose the required knowledge and Data Agent operations.'
    }
}

function Assert-PacEnvironment {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw 'Power Platform CLI is required.'
    }
    $output = & pac org who --environment $environmentUrl 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "PAC is not authenticated to '$environmentUrl'. Run: pac auth create --name caldova-private --tenant $($config.powerPlatform.tenantId) --environment $environmentUrl --deviceCode"
    }
    return $output
}

function Assert-PulledBindings {
    foreach ($agent in $agents) {
        $connectionPath = Join-Path $agent.Directory 'connectionreferences.mcs.yml'
        $connectionStatePath = Join-Path $agent.Directory '.mcs/conn.json'
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf) -or -not (Test-Path -LiteralPath $connectionStatePath -PathType Leaf)) {
            throw "Agent '$($agent.SchemaName)' must be bound in Copilot Studio and pulled before publication."
        }
        $componentFiles = if ($agent.Kind -eq 'lakehouse') {
            @(Get-ChildItem -LiteralPath (Join-Path $agent.Directory 'topics') -Filter '*.mcs.yml' -File -ErrorAction SilentlyContinue)
        }
        else {
            @(Get-ChildItem -LiteralPath (Join-Path $agent.Directory 'actions') -Filter '*.mcs.yml' -File -ErrorAction SilentlyContinue)
        }
        $content = ($componentFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        foreach ($pattern in $agent.RequiredPatterns) {
            if ($content -notmatch $pattern) {
                throw "Pulled '$($agent.SchemaName)' source is missing required binding evidence '$pattern'."
            }
        }
    }
}

Assert-DesiredState
$operations = [System.Collections.Generic.List[string]]::new()
$operations.Add('validated')

if ($ProvisionConnectors) {
    $null = & (Join-Path $PSScriptRoot 'create-connectors.ps1') -ConfigPath $ConfigPath -IdentityPath $IdentityPath
    $operations.Add('connectors-provisioned')
}

if ($ImportBaselines -or $Publish) {
    $null = Assert-PacEnvironment
}

if ($ImportBaselines) {
    $packages = @(& (Join-Path $PSScriptRoot 'package-agents.ps1') -ConfigPath $ConfigPath |
        Where-Object { $_ -isnot [string] -and $_.PSObject.Properties.Name -contains 'PackagePath' })
    if ($packages.Count -ne $agents.Count) {
        throw "Expected $($agents.Count) Copilot Studio packages but found $($packages.Count)."
    }
    foreach ($package in $packages) {
        & pac solution import --environment $environmentUrl --path $package.PackagePath --publish-changes
        if ($LASTEXITCODE -ne 0) { throw "Unable to import '$($package.SolutionName)'." }
    }
    $operations.Add('baselines-imported')
}

if ($Publish) {
    Assert-PulledBindings
    foreach ($agent in $agents) {
        & pac copilot push --project-dir $agent.Directory
        if ($LASTEXITCODE -ne 0) { throw "Unable to push '$($agent.SchemaName)'." }
        & pac copilot publish --environment $environmentUrl --bot $agent.SchemaName
        if ($LASTEXITCODE -ne 0) { throw "Unable to publish '$($agent.SchemaName)'." }
    }
    $operations.Add('agents-published')
}

$result = [ordered]@{
    schemaVersion = 1
    environmentId = $environmentId
    environmentUrl = $environmentUrl
    operations = @($operations)
    agents = @($agents | ForEach-Object {
        [ordered]@{
            kind = $_.Kind
            schemaName = $_.SchemaName
            connectorName = $_.ConnectorName
        }
    })
}
$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutputPath) -Force
[IO.File]::WriteAllText($resolvedOutputPath, (($result | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
