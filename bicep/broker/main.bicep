targetScope = 'resourceGroup'

@description('Azure region from azure.location in the shared deployment configuration.')
param location string = resourceGroup().location

@description('Function App name from broker.appName in the shared deployment configuration.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Existing Linux B1 App Service plan name from broker.existingPlanName.')
param existingPlanName string

@description('Existing Fabric broker virtual network resource ID from network.brokerVnetResourceId.')
param brokerVnetResourceId string

@description('Existing private endpoint subnet resource ID from network.brokerPrivateEndpointSubnetResourceId.')
param privateEndpointSubnetResourceId string

@description('Existing Function VNet integration subnet resource ID from network.brokerIntegrationSubnetResourceId.')
param integrationSubnetResourceId string

@description('Existing privatelink.azurewebsites.net VNet link name. Leave empty to create a dedicated link.')
param existingWebPrivateDnsVnetLinkName string = ''

@description('Existing private Blob DNS VNet link name. Leave empty to create a dedicated link.')
param existingBlobPrivateDnsVnetLinkName string = ''

@description('Azure deployment tenant ID from azure.tenantId.')
param azureTenantId string

@description('Resource tenant ID from identity.resourceTenantId.')
param resourceTenantId string

@description('Caller tenant ID from identity.callerTenantId.')
param callerTenantId string

@description('Generated client ID of the Fabric-tenant broker API app registration. Required when deployFunction is true.')
param entraApiClientId string = ''

@description('Generated v2 access-token audience GUID. Required when deployFunction is true.')
param brokerAudience string = ''

@description('Generated object ID of the APIM managed identity in the caller tenant. Required when deployFunction is true.')
param apimPrincipalId string = ''

@description('Generated connector application client IDs allowed to call the broker. Required when deployFunction is true.')
param allowedConnectorClientIds array = []

@description('Explicit user object IDs allowed to use the broker. Required when deployFunction is true.')
param allowedUserObjectIds array = []

@description('Object ID of the current deployment principal that receives Key Vault Secrets Officer and Storage Blob Data Contributor.')
param currentDeployerPrincipalId string

@description('Private blob container used for Function deployment packages.')
@minLength(3)
@maxLength(63)
param deploymentContainerName string = 'deployments'

@description('Blob name of the Function deployment package.')
@minLength(1)
@maxLength(1024)
param packageBlobName string = 'fabric-obo-broker.zip'

@description('Versionless Key Vault secret name containing the OBO application credential. The secret value is never deployed by this template.')
@minLength(1)
param oboClientSecretName string = 'obo-client-secret'

@description('Deploy the Function App and its private endpoint after generated identity values and allowlists are ready.')
param deployFunction bool = false

@description('Application role required on APIM application tokens.')
param brokerApplicationRole string

@description('Delegated scope required on user tokens.')
param delegatedScope string

@description('Fixed Microsoft Fabric API scope.')
param fabricApiScope string

@description('Fixed Power BI API scope.')
param powerBiApiScope string

@description('Fabric workspace ID.')
param fabricWorkspaceId string

@description('Fabric lakehouse name.')
param fabricLakehouseName string

@description('Fabric SQL endpoint host name.')
param fabricSqlEndpointHost string

@description('Fabric data agent ID.')
param fabricDataAgentId string

@description('Windows App Service Node version from broker.runtime.')
param runtime string = '~22'

@description('Whether Always On is enabled on the existing dedicated plan.')
param alwaysOn bool = true

@minValue(1)
param jwkFetchTimeoutMs int = 5000

@minValue(1)
param tokenExchangeTimeoutMs int = 15000

@minValue(1)
param sqlConnectTimeoutMs int = 30000

@minValue(1)
param sqlRequestTimeoutMs int = 120000

@minValue(1)
@maxValue(10000)
param maxRows int = 1000

@minValue(1)
@maxValue(100000)
param maxStatementLength int = 10000

@description('APIM API IDs included in tokenomics aggregation. Dashboard self-traffic must be excluded.')
@minLength(1)
param tokenomicsApimApiIds array

@description('Governed business project dimension for this deployment.')
param tokenomicsProjectId string

@description('Governed team dimension for this deployment.')
param tokenomicsTeamId string

@description('Governed cost-center dimension for this deployment.')
param tokenomicsCostCenter string

@description('ISO 4217 reporting currency for the tokenomics rate card.')
param tokenomicsCurrency string = 'USD'

@description('Effective-dated token rate card serialized as JSON. An empty array disables cost estimates without disabling usage telemetry.')
param tokenomicsRateCardJson string = '[]'

@description('Configured APIM API-to-application attribution map serialized as JSON.')
param tokenomicsApiAttributionJson string = '{}'

@description('Enable read-only Azure Cost Management ActualCost queries.')
param actualCostEnabled bool = false

@description('Resource-group scope used for ActualCost queries.')
param actualCostScope string

@description('Pinned Azure Cost Management query API version.')
param actualCostQueryApiVersion string = '2023-11-01'

@description('Expected maximum Azure billing ingestion lag displayed by the UI.')
@minValue(1)
@maxValue(168)
param actualCostBillingLagHours int = 24

@description('Tracked billing resources serialized as JSON.')
param actualCostTrackedResourcesJson string

@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@minValue(1)
@maxValue(365)
param blobDeleteRetentionDays int = 7

@description('Customer tags from the shared deployment configuration.')
param tags object = {}

var compactAppName = toLower(replace(functionAppName, '-', ''))
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, functionAppName)
var identityName = take('id-${functionAppName}', 128)
var storageAccountName = take('st${compactAppName}${uniqueSuffix}', 24)
var keyVaultName = take('kv-${functionAppName}-${uniqueSuffix}', 24)
var logAnalyticsWorkspaceName = take('log-${functionAppName}', 63)
var applicationInsightsName = take('appi-${functionAppName}', 260)
var functionPrivateEndpointName = take('pe-${functionAppName}-sites', 64)
var blobPrivateEndpointName = take('pe-${functionAppName}-blob', 64)
var tablePrivateEndpointName = take('pe-${functionAppName}-table', 64)
var vaultPrivateEndpointName = take('pe-${functionAppName}-vault', 64)
var webPrivateDnsZoneName = 'privatelink.azurewebsites.net'
var blobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var tablePrivateDnsZoneName = 'privatelink.table.${environment().suffixes.storage}'
var vaultPrivateDnsZoneName = 'privatelink.vaultcore.azure.net'
var keyVaultSecretReference = '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/${oboClientSecretName})'
var deploymentPackageBlobUrl = 'https://${storageAccountName}.blob.${environment().suffixes.storage}/${deploymentContainerName}/${packageBlobName}'

var storageBlobDataContributorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageRoleDefinitionIds = [
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b') // Storage Blob Data Owner
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3') // Storage Table Data Contributor for host diagnostics
]
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
var logAnalyticsReaderRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
var actualCostRoleDefinitionIds = [
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '72fafb9e-0641-4937-9268-a91bfd8191a3') // Cost Management Reader
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05') // Monitoring Reader
  subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
]

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' existing = {
  name: existingPlanName
}

module generatedIdentityInputGuard './generated-input-guard.bicep' = if (deployFunction) {
  name: 'validate-generated-identity-inputs'
  params: {
    allowedConnectorClientIds: allowedConnectorClientIds
    allowedUserObjectIds: allowedUserObjectIds
    apimPrincipalId: apimPrincipalId
    brokerAudience: brokerAudience
    entraApiClientId: entraApiClientId
  }
}

resource brokerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    isHnsEnabled: false
    isLocalUserEnabled: false
    isNfsV3Enabled: false
    isSftpEnabled: false
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    containerDeleteRetentionPolicy: {
      days: blobDeleteRetentionDays
      enabled: true
    }
    deleteRetentionPolicy: {
      allowPermanentDelete: false
      days: blobDeleteRetentionDays
      enabled: true
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'None'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    softDeleteRetentionInDays: 90
    tenantId: azureTenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: logRetentionDays
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    DisableIpMasking: false
    IngestionMode: 'LogAnalytics'
    RetentionInDays: logRetentionDays
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource storageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in storageRoleDefinitionIds: {
  scope: storageAccount
  name: guid(storageAccount.id, brokerIdentity.id, roleDefinitionId)
  properties: {
    principalId: brokerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}]

resource identityKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, brokerIdentity.id, keyVaultSecretsUserRoleDefinitionId)
  properties: {
    principalId: brokerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
  }
}

resource deployerKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, currentDeployerPrincipalId, keyVaultSecretsOfficerRoleDefinitionId)
  properties: {
    principalId: currentDeployerPrincipalId
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
  }
}

resource deployerStorageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, currentDeployerPrincipalId, storageBlobDataContributorRoleDefinitionId)
  properties: {
    principalId: currentDeployerPrincipalId
    roleDefinitionId: storageBlobDataContributorRoleDefinitionId
  }
}

resource identityLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: logAnalyticsWorkspace
  name: guid(logAnalyticsWorkspace.id, brokerIdentity.id, logAnalyticsReaderRoleDefinitionId)
  properties: {
    principalId: brokerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReaderRoleDefinitionId
  }
}

resource identityActualCostReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in actualCostRoleDefinitionIds: if (actualCostEnabled) {
  name: guid(resourceGroup().id, brokerIdentity.id, roleDefinitionId)
  properties: {
    principalId: brokerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}]

resource webPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: webPrivateDnsZoneName
  location: 'global'
}

resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: blobPrivateDnsZoneName
  location: 'global'
}

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: tablePrivateDnsZoneName
  location: 'global'
}

resource vaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: vaultPrivateDnsZoneName
  location: 'global'
}

resource webPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(existingWebPrivateDnsVnetLinkName)) {
  parent: webPrivateDnsZone
  name: take('link-${functionAppName}-sites', 80)
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: brokerVnetResourceId
    }
  }
}

resource blobPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(existingBlobPrivateDnsVnetLinkName)) {
  parent: blobPrivateDnsZone
  name: take('link-${functionAppName}-blob', 80)
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: brokerVnetResourceId
    }
  }
}

resource tablePrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: tablePrivateDnsZone
  name: take('link-${functionAppName}-table', 80)
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    resolutionPolicy: 'Default'
    virtualNetwork: {
      id: brokerVnetResourceId
    }
  }
}

resource vaultPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: vaultPrivateDnsZone
  name: take('link-${functionAppName}-vault', 80)
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    resolutionPolicy: 'Default'
    virtualNetwork: {
      id: brokerVnetResourceId
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: blobPrivateEndpointName
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          groupIds: [
            'blob'
          ]
          privateLinkServiceId: storageAccount.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetResourceId
    }
  }
}

resource blobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZone.id
        }
      }
    ]
  }
}

resource tablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: tablePrivateEndpointName
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'table'
        properties: {
          groupIds: [
            'table'
          ]
          privateLinkServiceId: storageAccount.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetResourceId
    }
  }
}

resource tablePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: tablePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: tablePrivateDnsZone.id
        }
      }
    ]
  }
}

resource vaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: vaultPrivateEndpointName
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          groupIds: [
            'vault'
          ]
          privateLinkServiceId: keyVault.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetResourceId
    }
  }
}

resource vaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: vaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: vaultPrivateDnsZone.id
        }
      }
    ]
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = if (deployFunction) {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${brokerIdentity.id}': {}
    }
  }
  properties: {
    clientAffinityEnabled: false
    httpsOnly: true
    keyVaultReferenceIdentity: brokerIdentity.id
    publicNetworkAccess: 'Disabled'
    reserved: false
    serverFarmId: appServicePlan.id
    siteConfig: {
      alwaysOn: alwaysOn
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: runtime
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: deploymentPackageBlobUrl
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID'
          value: brokerIdentity.id
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: brokerIdentity.properties.clientId
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'RESOURCE_TENANT_ID'
          value: resourceTenantId
        }
        {
          name: 'CALLER_TENANT_ID'
          value: callerTenantId
        }
        {
          name: 'ENTRA_API_CLIENT_ID'
          value: entraApiClientId
        }
        {
          name: 'OBO_CLIENT_SECRET'
          value: keyVaultSecretReference
        }
        {
          name: 'BROKER_AUDIENCE'
          value: brokerAudience
        }
        {
          name: 'BROKER_APPLICATION_ROLE'
          value: brokerApplicationRole
        }
        {
          name: 'APIM_PRINCIPAL_ID'
          value: apimPrincipalId
        }
        {
          name: 'ALLOWED_CONNECTOR_CLIENT_IDS'
          value: join(allowedConnectorClientIds, ',')
        }
        {
          name: 'ALLOWED_USER_OBJECT_IDS'
          value: join(allowedUserObjectIds, ',')
        }
        {
          name: 'DELEGATED_SCOPE'
          value: delegatedScope
        }
        {
          name: 'FABRIC_API_SCOPE'
          value: fabricApiScope
        }
        {
          name: 'POWER_BI_API_SCOPE'
          value: powerBiApiScope
        }
        {
          name: 'FABRIC_WORKSPACE_ID'
          value: fabricWorkspaceId
        }
        {
          name: 'FABRIC_LAKEHOUSE_NAME'
          value: fabricLakehouseName
        }
        {
          name: 'FABRIC_SQL_ENDPOINT_HOST'
          value: fabricSqlEndpointHost
        }
        {
          name: 'FABRIC_DATA_AGENT_ID'
          value: fabricDataAgentId
        }
        {
          name: 'JWK_FETCH_TIMEOUT_MS'
          value: string(jwkFetchTimeoutMs)
        }
        {
          name: 'TOKEN_EXCHANGE_TIMEOUT_MS'
          value: string(tokenExchangeTimeoutMs)
        }
        {
          name: 'SQL_CONNECT_TIMEOUT_MS'
          value: string(sqlConnectTimeoutMs)
        }
        {
          name: 'SQL_REQUEST_TIMEOUT_MS'
          value: string(sqlRequestTimeoutMs)
        }
        {
          name: 'MAX_ROWS'
          value: string(maxRows)
        }
        {
          name: 'MAX_STATEMENT_LENGTH'
          value: string(maxStatementLength)
        }
        {
          name: 'MANAGED_IDENTITY_CLIENT_ID'
          value: brokerIdentity.properties.clientId
        }
        {
          name: 'LOG_ANALYTICS_WORKSPACE_ID'
          value: logAnalyticsWorkspace.properties.customerId
        }
        {
          name: 'TOKENOMICS_APIM_API_IDS'
          value: join(tokenomicsApimApiIds, ',')
        }
        {
          name: 'TOKENOMICS_PROJECT_ID'
          value: tokenomicsProjectId
        }
        {
          name: 'TOKENOMICS_TEAM_ID'
          value: tokenomicsTeamId
        }
        {
          name: 'TOKENOMICS_COST_CENTER'
          value: tokenomicsCostCenter
        }
        {
          name: 'TOKENOMICS_CURRENCY'
          value: tokenomicsCurrency
        }
        {
          name: 'TOKENOMICS_RATE_CARD_JSON'
          value: tokenomicsRateCardJson
        }
        {
          name: 'TOKENOMICS_API_ATTRIBUTION_JSON'
          value: tokenomicsApiAttributionJson
        }
        {
          name: 'ACTUAL_COST_ENABLED'
          value: string(actualCostEnabled)
        }
        {
          name: 'ACTUAL_COST_SCOPE'
          value: actualCostScope
        }
        {
          name: 'ACTUAL_COST_QUERY_API_VERSION'
          value: actualCostQueryApiVersion
        }
        {
          name: 'ACTUAL_COST_BILLING_LAG_HOURS'
          value: string(actualCostBillingLagHours)
        }
        {
          name: 'ACTUAL_COST_TRACKED_RESOURCES_JSON'
          value: actualCostTrackedResourcesJson
        }
      ]
      ftpsState: 'Disabled'
      http20Enabled: true
      ipSecurityRestrictionsDefaultAction: 'Deny'
      minTlsVersion: '1.2'
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: true
      scmMinTlsVersion: '1.2'
      use32BitWorkerProcess: false
      vnetRouteAllEnabled: true
    }
    virtualNetworkSubnetId: integrationSubnetResourceId
  }
  dependsOn: [
    generatedIdentityInputGuard
    deploymentContainer
    storageRoleAssignments
    deployerStorageBlobDataContributor
    identityKeyVaultSecretsUser
    identityLogAnalyticsReader
    identityActualCostReaders
    blobPrivateDnsVnetLink
    tablePrivateDnsVnetLink
    vaultPrivateDnsVnetLink
    blobPrivateDnsZoneGroup
    tablePrivateDnsZoneGroup
    vaultPrivateDnsZoneGroup
  ]
}

resource scmBasicPublishingCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = if (deployFunction) {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpBasicPublishingCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = if (deployFunction) {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource functionDiagnosticSetting 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployFunction) {
  scope: functionApp
  name: 'function-logs'
  properties: {
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    workspaceId: logAnalyticsWorkspace.id
  }
}

resource functionPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (deployFunction) {
  name: functionPrivateEndpointName
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          groupIds: [
            'sites'
          ]
          privateLinkServiceId: functionApp.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnetResourceId
    }
  }
}

resource functionPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (deployFunction) {
  parent: functionPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: webPrivateDnsZone.id
        }
      }
    ]
  }
}

output functionUrl string = deployFunction ? 'https://${functionApp!.properties.defaultHostName}' : ''
output functionPrivateEndpointIp string = deployFunction ? functionPrivateEndpoint!.properties.customDnsConfigs[0].ipAddresses[0] : ''
output keyVaultName string = keyVault.name
output storageAccountName string = storageAccount.name
output deploymentContainerId string = deploymentContainer.id
output packageBlobUrl string = deploymentPackageBlobUrl
output applicationInsightsName string = applicationInsights.name
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceCustomerId string = logAnalyticsWorkspace.properties.customerId
output userAssignedIdentityPrincipalId string = brokerIdentity.properties.principalId
output userAssignedIdentityClientId string = brokerIdentity.properties.clientId
