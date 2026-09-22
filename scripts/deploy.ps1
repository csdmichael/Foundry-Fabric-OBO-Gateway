[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '../config/deployment.json'),
    [string] $IdentityPath = (Join-Path $PSScriptRoot '../.generated/identity.json'),
    [ValidateSet('preflight', 'apim-base', 'network-apim', 'network-broker', 'broker-base', 'foundry-base', 'identity', 'package', 'broker-app', 'apim', 'foundry-connections', 'foundry-agents', 'copilot-studio', 'all')]
    [string] $Step = 'preflight',
    [switch] $WhatIf,
    [switch] $InviteConfiguredAdmin,
    [switch] $RemoveStaleGrants,
    [string] $ResourceApiObjectId,
    [string] $LakehouseConnectorObjectId,
    [string] $DataAgentConnectorObjectId,
    [string] $DashboardClientObjectId,
    [string] $FoundryLakehouseOAuthClientObjectId,
    [string] $FoundryDataAgentOAuthClientObjectId,
    [string] $BrokerApiObjectId,
    [string] $CurrentDeployerPrincipalId,
    [string] $UploadIpAddress,
    [string] $ApplicationInsightsName = '',
    [string] $ApplicationInsightsResourceGroupName = '',
    [string] $RepositoryCommit = '',
    [switch] $AllowWhatIfModify,
    [switch] $ReusePrivateDnsZone,
    [switch] $SkipFoundrySmokeTest,
    [switch] $SkipFoundryEvaluations
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$config = Get-FabricDeploymentConfig -Path $ConfigPath
$fabricRoot = Split-Path -Parent $PSScriptRoot
$defaultConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $fabricRoot 'config/deployment.json'))
$resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if (-not [string]::Equals($defaultConfigPath, $resolvedConfigPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'deploy.ps1 accepts only config/deployment.json because the APIM and network Bicep entry points load that exact file.'
}
if ([bool]$config.deployment.deployWorkspacePrivateLink) {
    throw 'deployment.deployWorkspacePrivateLink must remain false while unsupported semantic models or external Copilot integrations exist.'
}
$generatedRoot = Join-Path $fabricRoot '.generated'
$parameterDirectory = Join-Path $generatedRoot 'parameters'
$whatIfDirectory = Join-Path $generatedRoot 'what-if'
$deploymentPrefix = [string]$config.deployment.environmentName
New-Item -ItemType Directory -Path $parameterDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $whatIfDirectory -Force | Out-Null

function Test-Step {
    param([string] $Name)
    $enabled = switch ($Name) {
        'apim-base' { [bool]$config.apim.createService }
        'network-apim' { [bool]$config.deployment.deployNetworking }
        'network-broker' { [bool]$config.deployment.deployNetworking }
        'broker-base' { [bool]$config.deployment.deployBroker }
        'foundry-base' { [bool]$config.deployment.deployFoundry }
        'identity' { [bool]$config.deployment.deployBroker }
        'package' { [bool]$config.deployment.deployBroker }
        'broker-app' { [bool]$config.deployment.deployBroker }
        'apim' { [bool]$config.deployment.deployApimApis }
        'foundry-connections' { [bool]$config.deployment.deployFoundry }
        'foundry-agents' { [bool]$config.deployment.deployFoundry }
        'copilot-studio' { [bool]$config.deployment.createCopilotStudioAgents }
        default { $true }
    }
    if ($Step -eq $Name -and -not $enabled) {
        throw "Deployment step '$Name' is disabled in deployment.json."
    }
    return ($Step -eq $Name) -or ($Step -eq 'all' -and $enabled)
}

function Complete-WhatIf {
    param([string] $Name, [string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "Azure what-if '$Name' returned no result."
    }
    $result = $Json | ConvertFrom-Json
    $changes = @($result.changes)
    $resultPath = Join-Path $whatIfDirectory "$Name.json"
    $result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resultPath -Encoding utf8
    $summary = @($changes | Group-Object changeType | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
    Write-Host "WHAT-IF ${Name}: $($summary -join ', ')"
    foreach ($change in $changes) {
        Write-Host "  $($change.changeType) $($change.resourceId)"
    }
    try {
        $null = Assert-FabricWhatIfChanges -Changes $changes -AllowModify:$AllowWhatIfModify
    }
    catch {
        throw "Azure what-if '$Name' contains blocked changes. Review '$resultPath'; use -AllowWhatIfModify only after every modification is approved. Deletes and unsupported changes are always blocked. $($_.Exception.Message)"
    }
}

function Write-ArmParameters {
    param([string] $Path, [hashtable] $Values)
    $parameters = [ordered]@{}
    foreach ($name in $Values.Keys) {
        $parameters[$name] = [ordered]@{ value = $Values[$name] }
    }
    [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-GroupDeployment {
    param(
        [string] $Name,
        [string] $SubscriptionId,
        [string] $ResourceGroup,
        [string] $TemplateFile,
        [string] $ParametersFile
    )
    $arguments = @('deployment', 'group')
    $arguments += if ($WhatIf) { 'what-if' } else { 'create' }
    $arguments += @('--subscription', $SubscriptionId, '--resource-group', $ResourceGroup, '--name', $Name, '--template-file', $TemplateFile, '--only-show-errors')
    if ($ParametersFile) {
        $arguments += @('--parameters', "@$ParametersFile")
    }
    if ($WhatIf) {
        $arguments += @('--no-pretty-print', '--result-format', 'FullResourcePayloads', '-o', 'json')
    }
    else {
        $arguments += @('--query', 'properties.outputs', '-o', 'json')
    }
    $output = az @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure deployment '$Name' failed."
    }
    if ($WhatIf) {
        Complete-WhatIf -Name $Name -Json ($output -join [Environment]::NewLine)
    }
    elseif ($output) {
        return $output | ConvertFrom-Json
    }
}

function Invoke-SubscriptionDeployment {
    param([string] $Name, [string] $TemplateFile, [string] $ParametersFile)
    $arguments = @('deployment', 'sub')
    $arguments += if ($WhatIf) { 'what-if' } else { 'create' }
    $arguments += @(
        '--subscription', [string]$config.apim.subscriptionId,
        '--location', [string]$config.azure.location,
        '--name', $Name,
        '--template-file', $TemplateFile,
        '--parameters', "@$ParametersFile",
        '--only-show-errors'
    )
    if ($WhatIf) {
        $arguments += @('--no-pretty-print', '--result-format', 'FullResourcePayloads', '-o', 'json')
    }
    else {
        $arguments += @('--query', 'properties.outputs', '-o', 'json')
    }
    $output = az @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure subscription deployment '$Name' failed."
    }
    if ($WhatIf) {
        Complete-WhatIf -Name $Name -Json ($output -join [Environment]::NewLine)
    }
    elseif ($output) {
        return $output | ConvertFrom-Json
    }
}

function Get-OutputValue {
    param([object] $Outputs, [string] $Name)
    $property = $Outputs.PSObject.Properties[$Name]
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value.value)) {
        throw "Deployment output '$Name' is missing."
    }
    return $property.Value.value
}

function Get-DeploymentOutputs {
    param([string] $Name, [string] $SubscriptionId, [string] $ResourceGroup)
    $json = az deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $Name --query properties.outputs -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Deployment outputs are unavailable for '$Name'."
    }
    return $json | ConvertFrom-Json
}

function Get-GraphObject {
    param([string] $Token, [string] $Path)
    return Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/$Path" -Headers @{ Authorization = "Bearer $Token" }
}

function Assert-LiveApplicationPair {
    param(
        [string] $Token,
        [object] $Metadata,
        [string] $ExpectedDisplayName,
        [string] $Label
    )
    $application = Get-GraphObject -Token $Token -Path "applications/$($Metadata.objectId)?`$select=id,appId,displayName"
    $principal = Get-GraphObject -Token $Token -Path "servicePrincipals/$($Metadata.servicePrincipalId)?`$select=id,appId,displayName"
    if ($application.id -ne $Metadata.objectId -or $application.appId -ne $Metadata.clientId -or $application.displayName -ne $ExpectedDisplayName -or
        $principal.id -ne $Metadata.servicePrincipalId -or $principal.appId -ne $Metadata.clientId) {
        throw "$Label metadata does not match its live application and service principal."
    }
}

function Assert-LiveIdentityMetadata {
    param([object] $Identity)
    $resourceToken = Get-FabricAzAccessToken -TenantId ([string]$config.identity.resourceTenantId) -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.azure.subscriptionId)
    $callerToken = Get-FabricAzAccessToken -TenantId ([string]$config.identity.callerTenantId) -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.apim.subscriptionId)
    try {
        Assert-LiveApplicationPair -Token $resourceToken -Metadata $Identity.resourceApi -ExpectedDisplayName ([string]$config.identity.apiDisplayName) -Label 'Resource API'
        foreach ($connector in $Identity.connectors) {
            $expectedName = if ($connector.kind -eq 'lakehouse') { [string]$config.identity.lakehouseConnectorDisplayName } else { [string]$config.identity.dataAgentConnectorDisplayName }
            Assert-LiveApplicationPair -Token $resourceToken -Metadata $connector -ExpectedDisplayName $expectedName -Label "$($connector.kind) connector"
        }
        foreach ($oauthClient in $Identity.foundryOAuthClients) {
            $expectedName = if ($oauthClient.kind -eq 'lakehouse') { [string]$config.foundry.mcpConnections.lakehouse.appDisplayName } else { [string]$config.foundry.mcpConnections.dataAgent.appDisplayName }
            Assert-LiveApplicationPair -Token $resourceToken -Metadata $oauthClient -ExpectedDisplayName $expectedName -Label "$($oauthClient.kind) Foundry OAuth client"
        }
        Assert-LiveApplicationPair -Token $resourceToken -Metadata $Identity.dashboardClient -ExpectedDisplayName ([string]$config.identity.dashboardClientDisplayName) -Label 'Dashboard SPA'
        Assert-LiveApplicationPair -Token $callerToken -Metadata $Identity.brokerApi -ExpectedDisplayName ([string]$config.identity.brokerApiDisplayName) -Label 'Broker API'
        $apimPrincipal = Get-GraphObject -Token $callerToken -Path "servicePrincipals/$($Identity.apimPrincipalId)?`$select=id"
        if ($apimPrincipal.id -ne $script:LiveApimPrincipalId) {
            throw 'APIM principal metadata does not match its live caller-tenant service principal.'
        }
    }
    finally {
        $resourceToken = $null
        $callerToken = $null
    }
}

function Get-IdentityMetadata {
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IdentityPath)
    if ($WhatIf -and -not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject]@{
            schemaVersion = 1
            resourceTenantId = [string]$config.identity.resourceTenantId
            callerTenantId = [string]$config.identity.callerTenantId
            resourceApi = [pscustomobject]@{ clientId = '11111111-1111-4111-8111-111111111111' }
            brokerApi = [pscustomobject]@{ clientId = '22222222-2222-4222-8222-222222222222' }
            apimPrincipalId = $script:LiveApimPrincipalId
            connectors = @(
                [pscustomobject]@{ kind = 'lakehouse'; clientId = '44444444-4444-4444-8444-444444444444' },
                [pscustomobject]@{ kind = 'dataAgent'; clientId = '55555555-5555-4555-8555-555555555555' }
            )
            foundryOAuthClients = @(
                [pscustomobject]@{ kind = 'lakehouse'; clientId = '99999999-9999-4999-8999-999999999999' },
                [pscustomobject]@{ kind = 'dataAgent'; clientId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
            )
            dashboardClient = [pscustomobject]@{ clientId = '77777777-7777-4777-8777-777777777777' }
            allowedUserObjectIds = @('66666666-6666-4666-8666-666666666666')
        }
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Identity metadata not found: $resolvedPath. Run the identity step first."
    }
    $identity = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    $expectedFingerprint = Get-FabricConfigFingerprint -Path $ConfigPath
    if ($identity.schemaVersion -ne 1 -or $identity.configFingerprint -ne $expectedFingerprint -or $identity.resourceTenantId -ne $config.identity.resourceTenantId -or $identity.callerTenantId -ne $config.identity.callerTenantId) {
        throw 'Identity metadata fingerprint, schema, or tenant IDs do not match deployment.json.'
    }
    $connectorKinds = @($identity.connectors.kind | Sort-Object)
    if ($connectorKinds.Count -ne 2 -or $connectorKinds[0] -ne 'dataAgent' -or $connectorKinds[1] -ne 'lakehouse') {
        throw 'Identity metadata must contain exactly one dataAgent and one lakehouse connector.'
    }
    $foundryOAuthKinds = @($identity.foundryOAuthClients.kind | Sort-Object)
    if ($foundryOAuthKinds.Count -ne 2 -or $foundryOAuthKinds[0] -ne 'dataAgent' -or $foundryOAuthKinds[1] -ne 'lakehouse') {
        throw 'Identity metadata must contain exactly one dataAgent and one lakehouse Foundry OAuth client.'
    }
    $null = Assert-FabricGuid -Value $identity.resourceApi.clientId -Name 'identity.resourceApi.clientId'
    $null = Assert-FabricGuid -Value $identity.brokerApi.clientId -Name 'identity.brokerApi.clientId'
    $null = Assert-FabricGuid -Value $identity.apimPrincipalId -Name 'identity.apimPrincipalId'
    $null = Assert-FabricGuidList -Values @($identity.connectors.clientId) -Name 'identity.connectors.clientId'
    $null = Assert-FabricGuidList -Values @($identity.foundryOAuthClients.clientId) -Name 'identity.foundryOAuthClients.clientId'
    $null = Assert-FabricGuid -Value $identity.dashboardClient.clientId -Name 'identity.dashboardClient.clientId'
    $null = Assert-FabricGuidList -Values @($identity.allowedUserObjectIds) -Name 'identity.allowedUserObjectIds'
    if ($identity.apimPrincipalId -ne $script:LiveApimPrincipalId) {
        throw 'Identity metadata APIM principal does not match the configured live APIM managed identity.'
    }
    Assert-LiveIdentityMetadata -Identity $identity
    return $identity
}

function Get-BrokerParameters {
    param([bool] $DeployFunction, [object] $Identity)
    $connectorClientIds = [object[]]@()
    $allowedUserObjectIds = [object[]]@()
    if ($DeployFunction) {
        $connectorClientIds = [object[]]@($Identity.connectors.clientId) + [object[]]@($Identity.foundryOAuthClients.clientId) + [object[]]@($Identity.dashboardClient.clientId)
        $allowedUserObjectIds = [object[]]@($Identity.allowedUserObjectIds)
    }
    return @{
        location = [string]$config.azure.location
        functionAppName = [string]$config.broker.appName
        existingPlanName = [string]$config.broker.existingPlanName
        brokerVnetResourceId = [string]$config.network.brokerVnetResourceId
        privateEndpointSubnetResourceId = [string]$config.network.brokerPrivateEndpointSubnetResourceId
        integrationSubnetResourceId = [string]$config.network.brokerIntegrationSubnetResourceId
        existingWebPrivateDnsVnetLinkName = [string]$config.network.brokerExistingPrivateDnsVnetLinks.web
        existingBlobPrivateDnsVnetLinkName = [string]$config.network.brokerExistingPrivateDnsVnetLinks.blob
        azureTenantId = [string]$config.azure.tenantId
        resourceTenantId = [string]$config.identity.resourceTenantId
        callerTenantId = [string]$config.identity.callerTenantId
        entraApiClientId = if ($DeployFunction) { [string]$Identity.resourceApi.clientId } else { '' }
        brokerAudience = if ($DeployFunction) { [string]$Identity.brokerApi.clientId } else { '' }
        apimPrincipalId = if ($DeployFunction) { [string]$Identity.apimPrincipalId } else { '' }
        allowedConnectorClientIds = $connectorClientIds
        allowedUserObjectIds = $allowedUserObjectIds
        currentDeployerPrincipalId = $CurrentDeployerPrincipalId
        deploymentContainerName = 'deployments'
        packageBlobName = 'fabric-obo-broker.zip'
        oboClientSecretName = 'obo-client-secret'
        deployFunction = $DeployFunction
        brokerApplicationRole = [string]$config.identity.brokerApplicationRole
        delegatedScope = [string]$config.identity.delegatedScope
        fabricApiScope = [string]$config.identity.fabricApiScope
        powerBiApiScope = [string]$config.identity.powerBiApiScope
        fabricWorkspaceId = [string]$config.fabric.workspaceId
        fabricLakehouseName = [string]$config.fabric.lakehouseName
        fabricSqlEndpointHost = [string]$config.fabric.sqlEndpointHost
        fabricDataAgentId = [string]$config.fabric.dataAgentId
        runtime = [string]$config.broker.runtime
        alwaysOn = [bool]$config.broker.alwaysOn
        jwkFetchTimeoutMs = [int]$config.broker.jwkFetchTimeoutMs
        tokenExchangeTimeoutMs = [int]$config.broker.tokenExchangeTimeoutMs
        sqlConnectTimeoutMs = [int]$config.broker.sqlConnectTimeoutMs
        sqlRequestTimeoutMs = [int]$config.broker.sqlRequestTimeoutMs
        maxRows = [int]$config.broker.maxRows
        maxStatementLength = [int]$config.broker.maxStatementLength
        tokenomicsApimApiIds = @(
            [string]$config.apim.lakehouseApiId
            [string]$config.apim.dataAgentApiId
            "$($config.apim.lakehouseApiId)-mcp"
            "$($config.apim.dataAgentApiId)-mcp"
            [string]$config.apim.inferenceApis.lakehouse.id
            [string]$config.apim.inferenceApis.dataAgent.id
        )
        tokenomicsProjectId = [string]$config.tokenomics.projectId
        tokenomicsTeamId = [string]$config.tokenomics.teamId
        tokenomicsCostCenter = [string]$config.tokenomics.costCenter
        tokenomicsCurrency = [string]$config.tokenomics.currency
        tokenomicsRateCardJson = ConvertTo-Json -InputObject @($config.tokenomics.rateCard) -Depth 10 -Compress
        tokenomicsApiAttributionJson = ConvertTo-Json -InputObject ([ordered]@{
            ([string]$config.apim.inferenceApis.lakehouse.id) = [string]$config.foundry.agents.lakehouse
            ([string]$config.apim.inferenceApis.dataAgent.id) = [string]$config.foundry.agents.dataAgent
        }) -Depth 10 -Compress
        actualCostEnabled = [bool]$config.tokenomics.actualCost.enabled
        actualCostScope = [string]$config.tokenomics.actualCost.scope
        actualCostQueryApiVersion = [string]$config.tokenomics.actualCost.queryApiVersion
        actualCostBillingLagHours = [int]$config.tokenomics.actualCost.billingLagHours
        actualCostTrackedResourcesJson = ConvertTo-Json -InputObject @($config.tokenomics.actualCost.trackedResources) -Depth 10 -Compress
        tags = $config.tags
    }
}

function Invoke-Preflight {
    $resourceContext = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    if ([string]::IsNullOrWhiteSpace($CurrentDeployerPrincipalId)) {
        $resourceGraphToken = Get-FabricAzAccessToken -TenantId ([string]$config.azure.tenantId) -Resource 'https://graph.microsoft.com/' -SubscriptionId ([string]$config.azure.subscriptionId)
        try {
            $signedInUser = Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id' -Headers @{ Authorization = "Bearer $resourceGraphToken" }
            $script:CurrentDeployerPrincipalId = [string]$signedInUser.id
        }
        catch {
            throw 'Resolve CurrentDeployerPrincipalId explicitly when the Azure CLI identity is not a user.'
        }
        finally {
            $resourceGraphToken = $null
        }
    }
    $script:CurrentDeployerPrincipalId = Assert-FabricGuid -Value $script:CurrentDeployerPrincipalId -Name 'CurrentDeployerPrincipalId'
    foreach ($resourceId in @($config.network.brokerVnetResourceId, $config.network.brokerPrivateEndpointSubnetResourceId, $config.network.brokerIntegrationSubnetResourceId)) {
        az resource show --ids $resourceId --subscription $config.azure.subscriptionId --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) { throw "Configured broker network resource is unavailable: $resourceId" }
    }
    $sharedPrivateDnsLinks = @(
        [pscustomobject]@{ Zone = 'privatelink.azurewebsites.net'; Name = [string]$config.network.brokerExistingPrivateDnsVnetLinks.web },
        [pscustomobject]@{ Zone = 'privatelink.blob.core.windows.net'; Name = [string]$config.network.brokerExistingPrivateDnsVnetLinks.blob }
    )
    foreach ($sharedLink in $sharedPrivateDnsLinks) {
        if ([string]::IsNullOrWhiteSpace($sharedLink.Name)) { continue }
        $linkJson = az network private-dns link vnet show --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --zone-name $sharedLink.Zone --name $sharedLink.Name --only-show-errors -o json
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($linkJson)) {
            throw "Configured shared private DNS link is unavailable: $($sharedLink.Zone)/$($sharedLink.Name)"
        }
        $link = $linkJson | ConvertFrom-Json
        if (-not [string]::Equals([string]$link.virtualNetwork.id, [string]$config.network.brokerVnetResourceId, [System.StringComparison]::OrdinalIgnoreCase) -or [bool]$link.registrationEnabled) {
            throw "Configured shared private DNS link does not target the broker VNet with registration disabled: $($sharedLink.Zone)/$($sharedLink.Name)"
        }
    }
    $planId = "/subscriptions/$($config.azure.subscriptionId)/resourceGroups/$($config.azure.resourceGroup)/providers/Microsoft.Web/serverfarms/$($config.broker.existingPlanName)"
    az resource show --ids $planId --subscription $config.azure.subscriptionId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw "Configured App Service plan is unavailable: $planId" }

    $callerContext = Assert-FabricAzureContext -SubscriptionId ([string]$config.apim.subscriptionId) -TenantId ([string]$config.apim.tenantId)
    az resource show --ids $config.network.apimVnetResourceId --subscription $config.apim.subscriptionId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw "Configured APIM VNet is unavailable: $($config.network.apimVnetResourceId)" }
    if (-not [string]::Equals([string]$config.foundry.vnetResourceId, [string]$config.network.apimVnetResourceId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Foundry VNet must match the configured APIM VNet for this private deployment.'
    }
    $apimVnetName = $config.network.apimVnetResourceId.Split('/')[-1]
    $foundrySubnetJson = az network vnet subnet show --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --vnet-name $apimVnetName --name $config.foundry.agentSubnetName --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($foundrySubnetJson)) {
        $foundrySubnet = $foundrySubnetJson | ConvertFrom-Json
        $delegations = @($foundrySubnet.delegations.serviceName)
        if ($foundrySubnet.addressPrefix -ne $config.foundry.agentSubnetPrefix -or $delegations.Count -ne 1 -or $delegations[0] -ne 'Microsoft.App/environments') {
            throw "Existing Foundry subnet '$($config.foundry.agentSubnetName)' does not match the exclusive configured CIDR and delegation."
        }
    }
    else {
        $vnetSubnetsJson = az network vnet subnet list --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --vnet-name $apimVnetName --query '[].{name:name,prefix:addressPrefix}' -o json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the Foundry subnet CIDR.' }
        $cidrCollision = @($vnetSubnetsJson | ConvertFrom-Json | Where-Object { $_.prefix -eq $config.foundry.agentSubnetPrefix })
        if ($cidrCollision.Count -gt 0) {
            throw "Foundry subnet CIDR '$($config.foundry.agentSubnetPrefix)' is already in use by '$($cidrCollision[0].name)'."
        }
    }
    $apimJson = az apim show --subscription $config.apim.subscriptionId --resource-group $config.apim.resourceGroup --name $config.apim.serviceName --only-show-errors -o json 2>$null
    $apimExists = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($apimJson)
    if ($apimExists) {
        $apim = $apimJson | ConvertFrom-Json
        $expectedSubnetId = "$($config.network.apimVnetResourceId)/subnets/$($config.network.apimSubnetName)"
        $actualLocation = ([string]$apim.location -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        $expectedLocation = ([string]$config.apim.location -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        if ($actualLocation -ne $expectedLocation -or $apim.sku.name -ne $config.apim.skuName -or $apim.virtualNetworkType -ne 'External' -or
            $apim.virtualNetworkConfiguration.subnetResourceId -ne $expectedSubnetId -or $apim.publicNetworkAccess -ne $config.apim.publicNetworkAccess) {
            throw "Existing APIM '$($config.apim.serviceName)' does not match the dedicated single-tenant configuration."
        }
        $script:LiveApimPrincipalId = Assert-FabricGuid -Value $apim.identity.principalId -Name 'APIM system-assigned identity'
    }
    elseif (-not [bool]$config.apim.createService) {
        throw "Configured APIM service is unavailable and apim.createService is false: $($config.apim.serviceName)"
    }
    else {
        $armToken = Get-FabricAzAccessToken -TenantId ([string]$config.apim.tenantId) -SubscriptionId ([string]$config.apim.subscriptionId) -Resource 'https://management.azure.com/'
        try {
            $availability = Invoke-RestMethod -Method POST -Uri "https://management.azure.com/subscriptions/$($config.apim.subscriptionId)/providers/Microsoft.ApiManagement/checkNameAvailability?api-version=2024-05-01" -Headers @{ Authorization = "Bearer $armToken" } -ContentType 'application/json' -Body (@{ name = [string]$config.apim.serviceName } | ConvertTo-Json -Compress)
            if (-not $availability.nameAvailable) { throw "APIM name '$($config.apim.serviceName)' is unavailable: $($availability.reason) $($availability.message)" }
        }
        finally {
            $armToken = $null
        }
        if ($WhatIf) {
            $script:LiveApimPrincipalId = '33333333-3333-4333-8333-333333333333'
        }
    }

    [pscustomobject]@{
        ResourceSubscription = $resourceContext.name
        CallerSubscription = $callerContext.name
        CurrentDeployerPrincipalId = $CurrentDeployerPrincipalId
        WhatIf = [bool]$WhatIf
    }
}

$brokerBaseDeploymentName = "$deploymentPrefix-broker-base"
$brokerAppDeploymentName = "$deploymentPrefix-broker-app"
$apimBaseDeploymentName = "$deploymentPrefix-apim-base"
$foundryBaseDeploymentName = "$deploymentPrefix-foundry-base"
$foundryConnectionsDeploymentName = "$deploymentPrefix-foundry-connections"
$script:LiveApimPrincipalId = $null
$baseOutputs = $null
$appOutputs = $null
$foundryBaseOutputs = $null
$package = $null
$preflight = Invoke-Preflight
if ($Step -eq 'preflight') {
    return $preflight
}

if (Test-Step 'apim-base') {
    $apimBaseParameterPath = Join-Path $parameterDirectory 'apim-base.parameters.json'
    Write-ArmParameters -Path $apimBaseParameterPath -Values @{
        location = [string]$config.apim.location
        apimServiceName = [string]$config.apim.serviceName
        publisherEmail = [string]$config.apim.publisherEmail
        publisherName = [string]$config.apim.publisherName
        skuName = [string]$config.apim.skuName
        publicNetworkAccess = [string]$config.apim.publicNetworkAccess
        vnetResourceId = [string]$config.network.apimVnetResourceId
        subnetName = [string]$config.network.apimSubnetName
        subnetPrefix = [string]$config.network.apimSubnetPrefix
        tags = $config.tags
    }
    $apimBaseOutputs = Invoke-GroupDeployment -Name $apimBaseDeploymentName -SubscriptionId $config.apim.subscriptionId -ResourceGroup $config.apim.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/apim/service.bicep') -ParametersFile $apimBaseParameterPath
    if (-not $WhatIf) {
        $script:LiveApimPrincipalId = Assert-FabricGuid -Value (Get-OutputValue -Outputs $apimBaseOutputs -Name 'apimPrincipalId') -Name 'APIM system-assigned identity'
    }
}

if (Test-Step 'network-apim') {
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.apim.subscriptionId) -TenantId ([string]$config.apim.tenantId)
    Invoke-GroupDeployment -Name "$deploymentPrefix-network-apim" -SubscriptionId $config.apim.subscriptionId -ResourceGroup $config.apim.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/network-apim-side/main.bicep') -ParametersFile '' | Out-Null
}

if (Test-Step 'network-broker') {
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    Invoke-GroupDeployment -Name "$deploymentPrefix-network-broker" -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/network-broker-side/main.bicep') -ParametersFile '' | Out-Null
}

if (Test-Step 'broker-base') {
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    $baseParameterPath = Join-Path $parameterDirectory 'broker-base.parameters.json'
    Write-ArmParameters -Path $baseParameterPath -Values (Get-BrokerParameters -DeployFunction $false -Identity $null)
    $baseOutputs = Invoke-GroupDeployment -Name $brokerBaseDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/broker/main.bicep') -ParametersFile $baseParameterPath
}

if (Test-Step 'foundry-base') {
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    $foundryBaseParameterPath = Join-Path $parameterDirectory 'foundry-base.parameters.json'
    Write-ArmParameters -Path $foundryBaseParameterPath -Values @{
        accountName = [string]$config.foundry.accountName
        projectName = [string]$config.foundry.projectName
        location = [string]$config.foundry.location
        vnetResourceId = [string]$config.foundry.vnetResourceId
        agentSubnetName = [string]$config.foundry.agentSubnetName
        agentSubnetPrefix = [string]$config.foundry.agentSubnetPrefix
        privateEndpointSubnetResourceId = [string]$config.foundry.privateEndpointSubnetResourceId
        modelName = [string]$config.foundry.model.name
        modelFormat = [string]$config.foundry.model.format
        modelVersion = [string]$config.foundry.model.version
        modelSkuName = [string]$config.foundry.model.skuName
        modelCapacity = [int]$config.foundry.model.capacity
        apimPrincipalId = [string]$script:LiveApimPrincipalId
        currentDeployerPrincipalId = [string]$CurrentDeployerPrincipalId
        tags = $config.tags
    }
    $foundryBaseOutputs = Invoke-GroupDeployment -Name $foundryBaseDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/foundry/main.bicep') -ParametersFile $foundryBaseParameterPath
}

if (Test-Step 'identity') {
    if ($WhatIf) {
        Write-Host 'SKIP identity mutation during what-if.'
    }
    else {
        if (-not $baseOutputs) {
            $baseOutputs = Get-DeploymentOutputs -Name $brokerBaseDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup
        }
        $identityParameters = @{
            ConfigPath = $ConfigPath
            OutputPath = $IdentityPath
            KeyVaultName = Get-OutputValue -Outputs $baseOutputs -Name 'keyVaultName'
            KeyVaultAccessIpAddress = $UploadIpAddress
            ApimPrincipalId = $script:LiveApimPrincipalId
            DeploymentReady = $true
            InviteConfiguredAdmin = [bool]$InviteConfiguredAdmin
            RemoveStaleGrants = [bool]$RemoveStaleGrants
        }
        foreach ($adoptionParameter in 'ResourceApiObjectId', 'LakehouseConnectorObjectId', 'DataAgentConnectorObjectId', 'DashboardClientObjectId', 'FoundryLakehouseOAuthClientObjectId', 'FoundryDataAgentOAuthClientObjectId', 'BrokerApiObjectId') {
            $adoptionValue = Get-Variable -Name $adoptionParameter -ValueOnly
            if (-not [string]::IsNullOrWhiteSpace([string]$adoptionValue)) {
                $identityParameters[$adoptionParameter] = $adoptionValue
            }
        }
        & (Join-Path $PSScriptRoot 'provision-identity.ps1') @identityParameters
    }
}

if (Test-Step 'package') {
    if ($WhatIf) {
        & (Join-Path $PSScriptRoot 'build-broker-package.ps1') -ConfigPath $ConfigPath
    }
    else {
        if (-not $baseOutputs) {
            $baseOutputs = Get-DeploymentOutputs -Name $brokerBaseDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup
        }
        $package = & (Join-Path $PSScriptRoot 'build-broker-package.ps1') -ConfigPath $ConfigPath
        $storageAccountName = Get-OutputValue -Outputs $baseOutputs -Name 'storageAccountName'
        if ([string]::IsNullOrWhiteSpace($UploadIpAddress)) {
            $UploadIpAddress = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org')).Trim()
        }
        if ($UploadIpAddress -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') {
            throw 'UploadIpAddress must be one IPv4 address without a CIDR suffix.'
        }
        $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
        $networkStateJson = az storage account show --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --name $storageAccountName --query '{publicNetworkAccess:publicNetworkAccess,defaultAction:networkRuleSet.defaultAction,ipRules:networkRuleSet.ipRules[].ipAddressOrRange}' -o json
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($networkStateJson)) {
            throw 'Unable to snapshot the storage network state before package upload.'
        }
        $networkState = $networkStateJson | ConvertFrom-Json
        if ($networkState.publicNetworkAccess -notin 'Enabled', 'Disabled' -or $networkState.defaultAction -notin 'Allow', 'Deny') {
            throw 'Storage network state contains an unsupported public access or default action value.'
        }
        $priorPublicNetworkAccess = [string]$networkState.publicNetworkAccess
        $priorDefaultAction = [string]$networkState.defaultAction
        $initialIpRules = @($networkState.ipRules | Where-Object { $_ } | Sort-Object -Unique)
        $uploadRule = $UploadIpAddress
        $hasEquivalentUploadRule = @($initialIpRules | Where-Object { $_ -eq $uploadRule -or $_ -eq "$UploadIpAddress/32" }).Count -gt 0
        $needsUploadRule = -not $hasEquivalentUploadRule
        $uploadRuleCreated = $false
        try {
            az storage account update --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --name $storageAccountName --public-network-access Enabled --default-action Deny --only-show-errors -o none
            if ($LASTEXITCODE -ne 0) { throw 'Unable to enable the temporary storage upload path.' }
            if ($needsUploadRule) {
                az storage account network-rule add --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --account-name $storageAccountName --ip-address $uploadRule --only-show-errors -o none
                if ($LASTEXITCODE -ne 0) { throw 'Unable to add the temporary storage upload rule.' }
                $uploadRuleCreated = $true
            }
            $storageToken = Get-FabricAzAccessToken -TenantId ([string]$config.azure.tenantId) -Resource 'https://storage.azure.com/' -SubscriptionId ([string]$config.azure.subscriptionId)
            try {
                Invoke-WebRequest -Method PUT -Uri "https://$storageAccountName.blob.core.windows.net/deployments/fabric-obo-broker.zip" -Headers @{
                    Authorization = "Bearer $storageToken"
                    'x-ms-version' = '2023-11-03'
                    'x-ms-blob-type' = 'BlockBlob'
                } -ContentType 'application/zip' -InFile $package.PackagePath | Out-Null
            }
            finally {
                $storageToken = $null
            }
        }
        finally {
            $restoreFailures = @()
            if ($uploadRuleCreated) {
                az storage account network-rule remove --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --account-name $storageAccountName --ip-address $uploadRule --only-show-errors -o none
                if ($LASTEXITCODE -ne 0) { $restoreFailures += 'remove temporary IP rule' }
            }
            az storage account update --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --name $storageAccountName --public-network-access $priorPublicNetworkAccess --default-action $priorDefaultAction --only-show-errors -o none
            if ($LASTEXITCODE -ne 0) { $restoreFailures += 'restore public access/default action' }
            $restoredStateJson = az storage account show --subscription $config.azure.subscriptionId --resource-group $config.azure.resourceGroup --name $storageAccountName --query '{publicNetworkAccess:publicNetworkAccess,defaultAction:networkRuleSet.defaultAction,ipRules:networkRuleSet.ipRules[].ipAddressOrRange}' -o json
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($restoredStateJson)) {
                $restoreFailures += 'read restored network state'
            }
            else {
                $restoredState = $restoredStateJson | ConvertFrom-Json
                $restoredIpRules = @($restoredState.ipRules | Where-Object { $_ } | Sort-Object -Unique)
                if ($restoredState.publicNetworkAccess -ne $priorPublicNetworkAccess -or $restoredState.defaultAction -ne $priorDefaultAction -or
                    ($restoredIpRules -join '|') -ne ($initialIpRules -join '|')) {
                    $restoreFailures += 'verify exact network state'
                }
            }
            if ($restoreFailures.Count -gt 0) {
                throw "Storage network restoration failed: $($restoreFailures -join ', '). Inspect the account before continuing."
            }
        }
    }
}

if (Test-Step 'broker-app') {
    $identity = Get-IdentityMetadata
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    $appParameterPath = Join-Path $parameterDirectory 'broker-app.parameters.json'
    Write-ArmParameters -Path $appParameterPath -Values (Get-BrokerParameters -DeployFunction $true -Identity $identity)
    $appOutputs = Invoke-GroupDeployment -Name $brokerAppDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/broker/main.bicep') -ParametersFile $appParameterPath
}

if (Test-Step 'apim') {
    $identity = Get-IdentityMetadata
    $foundryProjectMiClientId = '88888888-8888-4888-8888-888888888888'
    if (-not $WhatIf) {
        if (-not $foundryBaseOutputs) {
            $foundryBaseOutputs = Get-DeploymentOutputs -Name $foundryBaseDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup
        }
        $foundryProjectPrincipalId = Get-OutputValue -Outputs $foundryBaseOutputs -Name 'projectPrincipalId'
        $foundryProjectMiClientId = az ad sp show --id $foundryProjectPrincipalId --query appId -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($foundryProjectMiClientId)) {
            throw 'Unable to resolve the Foundry project managed-identity application ID. Rerun after Entra propagation completes.'
        }
        $foundryProjectMiClientId = Assert-FabricGuid -Value $foundryProjectMiClientId -Name 'Foundry project managed-identity application ID'
    }
    $effectiveApplicationInsightsName = if ([string]::IsNullOrWhiteSpace($ApplicationInsightsName)) { "appi-$($config.broker.appName)" } else { $ApplicationInsightsName }
    $effectiveApplicationInsightsResourceGroupName = if ([string]::IsNullOrWhiteSpace($ApplicationInsightsResourceGroupName)) { [string]$config.azure.resourceGroup } else { $ApplicationInsightsResourceGroupName }
    $logAnalyticsWorkspaceId = "/subscriptions/$($config.azure.subscriptionId)/resourceGroups/$($config.azure.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/log-$($config.broker.appName)"
    $apimParameterPath = Join-Path $parameterDirectory 'apim.parameters.json'
    Write-ArmParameters -Path $apimParameterPath -Values @{
        resourceApiClientId = [string]$identity.resourceApi.clientId
        lakehouseClientIds = @($identity.connectors | Where-Object { $_.kind -eq 'lakehouse' } | ForEach-Object { $_.clientId }) + @($identity.foundryOAuthClients | Where-Object { $_.kind -eq 'lakehouse' } | ForEach-Object { $_.clientId })
        dataAgentClientIds = @($identity.connectors | Where-Object { $_.kind -eq 'dataAgent' } | ForEach-Object { $_.clientId }) + @($identity.foundryOAuthClients | Where-Object { $_.kind -eq 'dataAgent' } | ForEach-Object { $_.clientId })
        tokenomicsClientIds = @($identity.dashboardClient.clientId)
        allowedUserObjectIds = @($identity.allowedUserObjectIds)
        brokerAudience = [string]$identity.brokerApi.clientId
        foundryProjectMiClientId = [string]$foundryProjectMiClientId
        brokerPrivateUrl = "https://$($config.broker.appName).azurewebsites.net"
        applicationInsightsName = $effectiveApplicationInsightsName
        applicationInsightsResourceGroupName = $effectiveApplicationInsightsResourceGroupName
        logAnalyticsWorkspaceId = $logAnalyticsWorkspaceId
    }
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.apim.subscriptionId) -TenantId ([string]$config.apim.tenantId)
    Invoke-SubscriptionDeployment -Name "$deploymentPrefix-apim" -TemplateFile (Join-Path $fabricRoot 'bicep/apim/main.bicep') -ParametersFile $apimParameterPath | Out-Null
}

if (Test-Step 'foundry-connections') {
    $null = Assert-FabricAzureContext -SubscriptionId ([string]$config.azure.subscriptionId) -TenantId ([string]$config.azure.tenantId)
    $foundryConnectionsParameterPath = Join-Path $parameterDirectory 'foundry-connections.parameters.json'
    Write-ArmParameters -Path $foundryConnectionsParameterPath -Values @{
        accountName = [string]$config.foundry.accountName
        projectName = [string]$config.foundry.projectName
        apimGatewayUrl = [string]$config.apim.gatewayUrl
        connections = @(
            [ordered]@{
                connectionName = [string]$config.foundry.modelConnections.lakehouse
                apiPath = [string]$config.apim.inferenceApis.lakehouse.path
                agentId = [string]$config.foundry.agents.lakehouse
            }
            [ordered]@{
                connectionName = [string]$config.foundry.modelConnections.dataAgent
                apiPath = [string]$config.apim.inferenceApis.dataAgent.path
                agentId = [string]$config.foundry.agents.dataAgent
            }
        )
        modelName = [string]$config.foundry.model.name
        modelFormat = [string]$config.foundry.model.format
        modelVersion = [string]$config.foundry.model.version
    }
    Invoke-GroupDeployment -Name $foundryConnectionsDeploymentName -SubscriptionId $config.azure.subscriptionId -ResourceGroup $config.azure.resourceGroup -TemplateFile (Join-Path $fabricRoot 'bicep/foundry/connections.bicep') -ParametersFile $foundryConnectionsParameterPath | Out-Null
}

if (Test-Step 'foundry-agents') {
    if ($WhatIf) {
        & python -m py_compile (Join-Path $PSScriptRoot 'provision-foundry-agents.py')
        if ($LASTEXITCODE -ne 0) { throw 'Foundry Prompt Agent helper syntax validation failed.' }
        Write-Host 'SKIP Foundry OAuth and Prompt Agent mutation during what-if.'
    }
    else {
        $null = Get-IdentityMetadata
        $foundryAgentParameters = @{
            ConfigPath = $ConfigPath
            IdentityPath = $IdentityPath
            FoundryAccessIpAddress = $UploadIpAddress
            SkipSmokeTest = [bool]$SkipFoundrySmokeTest
            SkipEvaluations = [bool]$SkipFoundryEvaluations
        }
        & (Join-Path $PSScriptRoot 'provision-foundry-agents.ps1') @foundryAgentParameters
    }
}

if (Test-Step 'copilot-studio') {
    if ($WhatIf) {
        & (Join-Path $PSScriptRoot 'provision-copilot-studio-agents.ps1') -ConfigPath $ConfigPath -IdentityPath $IdentityPath | Out-Null
        Write-Host 'PASS Copilot Studio desired-state validation; no cloud mutation performed.'
    }
    else {
        & (Join-Path $PSScriptRoot 'provision-copilot-studio-agents.ps1') -ConfigPath $ConfigPath -IdentityPath $IdentityPath -ProvisionConnectors -ImportBaselines
    }
}

[pscustomobject]@{
    Step = $Step
    WhatIf = [bool]$WhatIf
    BrokerBaseDeployment = $brokerBaseDeploymentName
    BrokerAppDeployment = $brokerAppDeploymentName
    ApimBaseDeployment = $apimBaseDeploymentName
    FoundryBaseDeployment = $foundryBaseDeploymentName
    FoundryConnectionsDeployment = $foundryConnectionsDeploymentName
}