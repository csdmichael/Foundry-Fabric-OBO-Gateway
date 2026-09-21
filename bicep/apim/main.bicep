targetScope = 'subscription'

var config = loadJsonContent('../../config/deployment.json')
var apimConfig = config.apim
var foundryConfig = config.foundry
var identityConfig = config.identity

@minLength(36)
@maxLength(36)
type entraIdentifier = string

@description('Generated client ID of the Fabric resource API application registration.')
param resourceApiClientId entraIdentifier

@description('Generated client IDs allowed to call the Lakehouse REST API and MCP tools.')
@minLength(1)
param lakehouseClientIds entraIdentifier[]

@description('Generated client IDs allowed to call the Data Agent REST API and MCP tool.')
@minLength(1)
param dataAgentClientIds entraIdentifier[]

@description('Fabric-tenant user object IDs allowed to call the APIs.')
@minLength(1)
param allowedUserObjectIds entraIdentifier[]

@description('Generated application client ID used as the private broker audience.')
param brokerAudience entraIdentifier

@description('Application client ID of the Foundry project system-assigned managed identity.')
param foundryProjectMiClientId entraIdentifier

@description('Fixed private broker origin, without an /api path or trailing slash.')
@minLength(1)
param brokerPrivateUrl string

@description('Optional existing Application Insights component name. Diagnostics are omitted when empty.')
param applicationInsightsName string = ''

@description('Resource group of the existing Application Insights component.')
param applicationInsightsResourceGroupName string = ''

@description('Existing Log Analytics workspace resource ID for APIM gateway and LLM token diagnostics.')
param logAnalyticsWorkspaceId string = ''

var effectiveApplicationInsightsResourceGroupName = empty(applicationInsightsResourceGroupName) ? apimConfig.resourceGroup : applicationInsightsResourceGroupName

module apimStack './stack.bicep' = {
  name: 'fabric-apim-stack'
  scope: resourceGroup(apimConfig.subscriptionId, apimConfig.resourceGroup)
  params: {
    apimServiceName: apimConfig.serviceName
    resourceTenantId: identityConfig.resourceTenantId
    callerTenantId: identityConfig.callerTenantId
    resourceApiClientId: resourceApiClientId
    delegatedScope: identityConfig.delegatedScope
    lakehouseClientIds: lakehouseClientIds
    dataAgentClientIds: dataAgentClientIds
    allowedUserObjectIds: allowedUserObjectIds
    brokerAudience: brokerAudience
    brokerRole: identityConfig.brokerApplicationRole
    brokerPrivateUrl: brokerPrivateUrl
    rateLimitCalls: apimConfig.rateLimitCalls
    rateLimitRenewalSeconds: apimConfig.rateLimitRenewalSeconds
    requestTimeoutSeconds: apimConfig.requestTimeoutSeconds
    lakehouseApiId: apimConfig.lakehouseApiId
    lakehouseApiPath: apimConfig.lakehouseApiPath
    lakehouseMcpDisplayName: apimConfig.lakehouseMcpDisplayName
    lakehouseMcpPath: apimConfig.lakehouseMcpPath
    dataAgentApiId: apimConfig.dataAgentApiId
    dataAgentApiPath: apimConfig.dataAgentApiPath
    dataAgentMcpDisplayName: apimConfig.dataAgentMcpDisplayName
    dataAgentMcpPath: apimConfig.dataAgentMcpPath
    foundryTenantId: config.azure.tenantId
    foundryProjectMiClientId: foundryProjectMiClientId
    foundryAccountName: foundryConfig.accountName
    foundryModelTokenLimitPerMinute: apimConfig.modelTokenLimitPerMinute
    foundryInferenceApis: [
      {
        id: apimConfig.inferenceApis.lakehouse.id
        path: apimConfig.inferenceApis.lakehouse.path
        agentId: foundryConfig.agents.lakehouse
      }
      {
        id: apimConfig.inferenceApis.dataAgent.id
        path: apimConfig.inferenceApis.dataAgent.path
        agentId: foundryConfig.agents.dataAgent
      }
    ]
    fabricProductId: apimConfig.fabricProductId
    foundryProductId: apimConfig.foundryProductId
    uiAllowedOrigin: ''
    applicationInsightsName: applicationInsightsName
    applicationInsightsResourceGroupName: effectiveApplicationInsightsResourceGroupName
  }
}

output apimPrincipalId string = apimStack.outputs.apimPrincipalId
output lakehouseApiUrl string = '${apimConfig.gatewayUrl}/${apimConfig.lakehouseApiPath}'
output dataAgentApiUrl string = '${apimConfig.gatewayUrl}/${apimConfig.dataAgentApiPath}'
output lakehouseMcpUrl string = '${apimConfig.gatewayUrl}/${apimConfig.lakehouseMcpPath}/mcp'
output dataAgentMcpUrl string = '${apimConfig.gatewayUrl}/${apimConfig.dataAgentMcpPath}/mcp'
output lakehouseInferenceUrl string = '${apimConfig.gatewayUrl}/${apimConfig.inferenceApis.lakehouse.path}'
output dataAgentInferenceUrl string = '${apimConfig.gatewayUrl}/${apimConfig.inferenceApis.dataAgent.path}'
output fabricProductId string = apimStack.outputs.fabricProductId
output foundryProductId string = apimStack.outputs.foundryProductId
