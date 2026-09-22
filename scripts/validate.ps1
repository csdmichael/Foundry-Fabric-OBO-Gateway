[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [switch] $DeploymentReady,
    [switch] $IncludeParity,
    [switch] $SkipTerraformInit
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$defaultConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $repositoryRoot 'config/deployment.json'))
$resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if (-not [string]::Equals($defaultConfigPath, $resolvedConfigPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'validate.ps1 accepts only config/deployment.json because the APIM and network Bicep entry points load that exact file.'
}

foreach ($path in 'azure.tenantId', 'azure.subscriptionId', 'fabric.workspaceId', 'fabric.lakehouseId', 'fabric.sqlEndpointId', 'fabric.dataAgentId', 'apim.tenantId', 'apim.subscriptionId', 'identity.resourceTenantId', 'identity.callerTenantId') {
    $null = Assert-FabricGuid -Value (Get-FabricConfigValue -Config $config -Path $path) -Name $path
}
if ($config.azure.tenantId -ne $config.identity.resourceTenantId) {
    throw 'azure.tenantId must match identity.resourceTenantId.'
}
if ($config.apim.tenantId -ne $config.identity.callerTenantId -or $config.powerPlatform.tenantId -ne $config.identity.callerTenantId) {
    throw 'APIM and Power Platform tenant IDs must match identity.callerTenantId.'
}
if ($config.azure.tenantId -ne $config.apim.tenantId -or $config.azure.tenantId -ne $config.powerPlatform.tenantId -or
    $config.azure.subscriptionId -ne $config.apim.subscriptionId -or $config.azure.resourceGroup -ne $config.apim.resourceGroup) {
    throw 'Fabric, broker, APIM, and Power Platform must use the same configured tenant; Azure resources must use one subscription and resource group.'
}
if ($config.network.mode -notin @('single-tenant-shared-vnet', 'single-tenant-existing-peering') -or [bool]$config.deployment.deployNetworking) {
    throw 'The active topology must use an existing single-tenant network path and must not deploy VNet peerings.'
}
if ($config.network.mode -eq 'single-tenant-shared-vnet' -and $config.network.apimVnetResourceId -ne $config.network.brokerVnetResourceId) {
    throw 'single-tenant-shared-vnet requires APIM and broker to use the same VNet.'
}
if ($config.network.mode -eq 'single-tenant-existing-peering' -and $config.network.apimVnetResourceId -eq $config.network.brokerVnetResourceId) {
    throw 'single-tenant-existing-peering requires distinct APIM and broker VNets.'
}
foreach ($path in 'apim.location', 'apim.serviceName', 'apim.skuName', 'apim.publisherEmail', 'apim.publisherName', 'apim.publicNetworkAccess', 'apim.inferenceApis.lakehouse.id', 'apim.inferenceApis.lakehouse.path', 'apim.inferenceApis.dataAgent.id', 'apim.inferenceApis.dataAgent.path', 'apim.fabricProductId', 'apim.foundryProductId', 'network.apimSubnetName', 'network.apimSubnetPrefix', 'foundry.accountName', 'foundry.projectName', 'foundry.location', 'foundry.agentSubnetName', 'foundry.agentSubnetPrefix', 'foundry.model.name', 'foundry.model.version', 'foundry.model.skuName', 'identity.allowedUserPrincipalName') {
    $null = Get-FabricConfigValue -Config $config -Path $path
}
if ($config.apim.publicNetworkAccess -notin @('Enabled', 'Disabled')) {
    throw 'apim.publicNetworkAccess must be Enabled or Disabled.'
}
if ($config.apim.fabricProductId -ne 'fabric' -or $config.apim.foundryProductId -ne 'foundry') {
    throw 'APIM product IDs must be exactly fabric and foundry.'
}
if ([bool]$config.deployment.deployWorkspacePrivateLink) {
    throw 'deployment.deployWorkspacePrivateLink must remain false while unsupported semantic models or external Copilot integrations exist.'
}
if ($config.identity.fabricApiScope -ne 'https://api.fabric.microsoft.com/.default' -or $config.identity.powerBiApiScope -ne 'https://analysis.windows.net/powerbi/api/.default') {
    throw 'Fabric and Power BI downstream scopes must use the approved fixed values.'
}
if ($config.fabric.sqlEndpointHost -notmatch '^[a-z0-9-]+\.datawarehouse\.fabric\.microsoft\.com$') {
    throw 'fabric.sqlEndpointHost is not a Microsoft Fabric SQL endpoint host.'
}
if ($config.apim.gatewayUrl -notmatch '^https://[a-z0-9-]+\.azure-api\.net/?$') {
    throw 'apim.gatewayUrl must be an HTTPS azure-api.net origin.'
}
if ($config.foundry.location -ne $config.apim.location -or $config.foundry.vnetResourceId -ne $config.network.apimVnetResourceId -or
    $config.foundry.privateEndpointSubnetResourceId -ne $config.network.apimPrivateEndpointSubnetResourceId -or
    $config.foundry.agentSubnetPrefix -notmatch '^10\.(?:\d{1,3}\.){2}0/24$' -or $config.foundry.model.name -ne 'gpt-5.6-sol' -or
    $config.foundry.model.version -ne '2026-07-09' -or $config.foundry.model.skuName -ne 'GlobalStandard' -or [int]$config.foundry.model.capacity -lt 1) {
    throw 'Private Foundry region, network, and pinned model configuration are invalid.'
}
$inferenceApiIds = @($config.apim.inferenceApis.lakehouse.id, $config.apim.inferenceApis.dataAgent.id)
$agentNames = @($config.foundry.agents.lakehouse, $config.foundry.agents.dataAgent)
if (@($inferenceApiIds | Select-Object -Unique).Count -ne 2 -or @($agentNames | Select-Object -Unique).Count -ne 2 -or
    @($config.foundry.mcpConnections.lakehouse.allowedTools) -join ',' -ne 'tables,query' -or @($config.foundry.mcpConnections.dataAgent.allowedTools) -join ',' -ne 'query') {
    throw 'Foundry per-agent gateway identities and MCP allowlists must be distinct and least privilege.'
}
if ($config.broker.runtime -ne '~22') {
    throw 'Broker must use Node 22.'
}
foreach ($path in 'network.brokerVnetResourceId', 'network.brokerPrivateEndpointSubnetResourceId', 'network.brokerIntegrationSubnetResourceId', 'network.apimVnetResourceId', 'foundry.vnetResourceId', 'foundry.privateEndpointSubnetResourceId') {
    $resourceId = [string](Get-FabricConfigValue -Config $config -Path $path)
    if ($resourceId -notmatch '^/subscriptions/[0-9a-f-]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+(?:/subnets/[^/]+)?$') {
        throw "$path is not a valid virtual network or subnet resource ID."
    }
}
foreach ($path in 'network.brokerExistingPrivateDnsVnetLinks.web', 'network.brokerExistingPrivateDnsVnetLinks.blob') {
    $linkName = [string](Get-FabricConfigValue -Config $config -Path $path)
    if ($linkName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,78}[A-Za-z0-9])?$') {
        throw "$path is not a valid private DNS VNet link name."
    }
}

if ($DeploymentReady) {
    $null = Assert-FabricGuid -Value $config.powerPlatform.environmentId -Name 'powerPlatform.environmentId'
    $null = Assert-FabricGuidList -Values @($config.identity.allowedUserObjectIds) -Name 'identity.allowedUserObjectIds'
}

Write-Host 'PASS configuration contract'

Push-Location $repositoryRoot
try {
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('run', 'build', '--prefix', 'functions/obo-broker') -Description 'Broker build'
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('test', '--prefix', 'functions/obo-broker') -Description 'Broker tests'
    Invoke-FabricNative -FilePath 'npm' -ArgumentList @('audit', '--prefix', 'functions/obo-broker', '--omit=dev') -Description 'Broker production dependency audit'
    
    $brokerBicep = Get-Content -LiteralPath (Join-Path $repositoryRoot 'bicep/broker/main.bicep') -Raw
    if ($brokerBicep -match "keyVaultName\}\.\$\{environment\(\)\.suffixes\.keyvaultDns") {
        throw 'Broker Key Vault references must not add a dot before environment().suffixes.keyvaultDns.'
    }
    Invoke-FabricNative -FilePath 'python' -ArgumentList @(
        '-m', 'py_compile',
        'scripts/foundry_knowledge.py',
        'scripts/foundry_evaluations.py',
        'scripts/provision-foundry-agents.py',
        'scripts/create-sales-poc-agents.py'
    ) -Description 'Foundry Python helper syntax'
    Invoke-FabricNative -FilePath 'python' -ArgumentList @(
        '-m', 'unittest',
        'scripts.test.test_foundry_knowledge',
        'scripts.test.test_foundry_evaluations',
        'scripts.test.test_agent_safety_contracts'
    ) -Description 'Foundry agent and evaluation tests'
    
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts/provision-copilot-studio-agents.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) { throw 'Copilot Studio agent provisioner has PowerShell parse errors.' }
    & (Join-Path $repositoryRoot 'scripts/provision-copilot-studio-agents.ps1') | Out-Null
    Write-Host 'PASS Copilot Studio desired-state and connector contracts'
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts/sync-parts-shortages-foundry-iq.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) { throw 'Foundry IQ parts-shortage snapshot helper has PowerShell parse errors.' }

    foreach ($file in Get-ChildItem (Join-Path $repositoryRoot 'apim/openapi/*.json')) {
        $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
    foreach ($file in Get-ChildItem (Join-Path $repositoryRoot 'apim/policies/*.xml')) {
        [xml]$policy = Get-Content -LiteralPath $file.FullName -Raw
        if ($policy.DocumentElement.Name -ne 'policies') {
            throw "Invalid APIM policy root in $($file.FullName)."
        }
    }
    Write-Host 'PASS APIM OpenAPI and policy syntax'

    $bicepFiles = @(
        'bicep/apim/service.bicep',
        'bicep/broker/main.bicep',
        'bicep/apim/main.bicep',
        'bicep/foundry/main.bicep',
        'bicep/foundry/connections.bicep'
    )
    foreach ($file in $bicepFiles) {
        $compiled = az bicep build --file $file --stdout
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($compiled)) {
            throw "Bicep build failed: $file"
        }
        az bicep lint --file $file
        if ($LASTEXITCODE -ne 0) {
            throw "Bicep lint failed: $file"
        }
    }
    Write-Host 'PASS Bicep build and lint'

    $terraformModules = @(
        'terraform/broker',
        'terraform/apim',
        'terraform/foundry'
    )
    if ($IncludeParity) {
        $terraformModules = @(Get-ChildItem (Join-Path $repositoryRoot 'terraform') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'versions.tf') } | ForEach-Object { "terraform/$($_.Name)" })
    }
    foreach ($module in $terraformModules) {
        if (-not $SkipTerraformInit) {
            Invoke-FabricNative -FilePath 'terraform' -ArgumentList @("-chdir=$module", 'init', '-backend=false') -Description "Terraform init $module"
        }
        Invoke-FabricNative -FilePath 'terraform' -ArgumentList @("-chdir=$module", 'validate') -Description "Terraform validate $module"
    }
    Write-Host 'PASS Terraform configuration'
}
finally {
    Pop-Location
}

Write-Host 'PASS pre-deployment validation'
