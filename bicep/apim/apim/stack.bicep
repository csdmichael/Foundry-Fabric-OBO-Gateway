targetScope = 'resourceGroup'

param apimServiceName string
param resourceTenantId string
param callerTenantId string
param resourceApiClientId string
param delegatedScope string
param lakehouseClientIds array
param dataAgentClientIds array
param tokenomicsClientIds array
param allowedUserObjectIds array
param brokerAudience string
param brokerRole string
param brokerPrivateUrl string
param rateLimitCalls int
param rateLimitRenewalSeconds int
param requestTimeoutSeconds int
param lakehouseApiId string
param lakehouseApiPath string
param lakehouseMcpDisplayName string
param lakehouseMcpPath string
param dataAgentApiId string
param dataAgentApiPath string
param dataAgentMcpDisplayName string
param dataAgentMcpPath string
param tokenomicsApiId string
param tokenomicsApiPath string
param foundryTenantId string
param foundryProjectMiClientId string
param foundryAccountName string
param foundryModelTokenLimitPerMinute int
param foundryInferenceApis array
param fabricProductId string
param foundryProductId string
param uiAllowedOrigin string
param applicationInsightsName string
param applicationInsightsResourceGroupName string
param logAnalyticsWorkspaceId string

var diagnosticsEnabled = !empty(applicationInsightsName)
var tokenomicsDiagnosticsEnabled = !empty(logAnalyticsWorkspaceId)
var loggerName = 'fabric-obo-insights'
var lakehouseMcpId = '${lakehouseApiId}-mcp'
var dataAgentMcpId = '${dataAgentApiId}-mcp'
var commonApiPolicy = loadTextContent('../../apim/policies/fabric-obo-api-policy.xml')
var foundryInferencePolicy = loadTextContent('../../apim/policies/foundry-inference-policy.xml')
var namedValueSettings = [
  { name: 'fabric-obo-resource-tenant-id', value: resourceTenantId }
  { name: 'fabric-obo-caller-tenant-id', value: callerTenantId }
  { name: 'fabric-obo-resource-api-client-id', value: resourceApiClientId }
  { name: 'fabric-obo-delegated-scope', value: delegatedScope }
  { name: 'fabric-obo-allowed-user-oids', value: join(allowedUserObjectIds, ',') }
  { name: 'fabric-obo-broker-audience', value: brokerAudience }
  { name: 'fabric-obo-broker-role', value: brokerRole }
  { name: 'fabric-obo-broker-private-url', value: brokerPrivateUrl }
  { name: 'fabric-obo-rate-limit-calls', value: string(rateLimitCalls) }
  { name: 'fabric-obo-rate-limit-renewal-seconds', value: string(rateLimitRenewalSeconds) }
  { name: 'fabric-obo-request-timeout-seconds', value: string(requestTimeoutSeconds) }
  { name: 'fabric-obo-ui-origin', value: uiAllowedOrigin }
  { name: 'foundry-tenant-id', value: foundryTenantId }
  { name: 'foundry-project-mi-client-id', value: foundryProjectMiClientId }
  { name: 'foundry-model-backend-url', value: 'https://${foundryAccountName}.openai.azure.com/openai' }
  { name: 'foundry-model-token-limit', value: string(foundryModelTokenLimitPerMinute) }
]

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = [for setting in namedValueSettings: {
  parent: apim
  name: setting.name
  properties: {
    displayName: setting.name
    value: setting.value
    secret: false
  }
}]

resource lakehouseApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: lakehouseApiId
  properties: {
    displayName: 'Fabric Lakehouse OAuth'
    description: 'Read-only Fabric Lakehouse operations using delegated OAuth through the private broker.'
    path: lakehouseApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../apim/openapi/lakehouse.json')
  }
}

resource dataAgentApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: dataAgentApiId
  properties: {
    displayName: 'Fabric Data Agent OAuth'
    description: 'Fabric Data Agent queries using delegated OAuth through the private broker.'
    path: dataAgentApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../apim/openapi/data-agent.json')
  }
}

resource tokenomicsApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: tokenomicsApiId
  properties: {
    displayName: 'Fabric Tokenomics'
    description: 'Privacy-preserving APIM request, token, allocation, and cost analytics.'
    path: tokenomicsApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../apim/openapi/tokenomics.json')
  }
}

resource foundryInferenceApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = [for inferenceApi in foundryInferenceApis: {
  parent: apim
  name: inferenceApi.id
  properties: {
    displayName: 'Foundry inference - ${inferenceApi.agentId}'
    description: 'Managed-identity AI Gateway route for ${inferenceApi.agentId}.'
    path: inferenceApi.path
    protocols: [
      'https'
    ]
    serviceUrl: 'https://${foundryAccountName}.openai.azure.com/openai'
    subscriptionRequired: false
  }
}]

resource foundryChatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [for (inferenceApi, index) in foundryInferenceApis: {
  parent: foundryInferenceApi[index]
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deploymentName}/chat/completions'
    templateParameters: [
      {
        name: 'deploymentName'
        type: 'string'
        required: true
      }
    ]
    request: {
      queryParameters: [
        {
          name: 'api-version'
          type: 'string'
          required: false
        }
      ]
    }
  }
}]

resource foundryInferenceApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = [for (inferenceApi, index) in foundryInferenceApis: {
  parent: foundryInferenceApi[index]
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(foundryInferencePolicy, '__AGENT_ID__', inferenceApi.agentId)
  }
  dependsOn: [
    namedValues
  ]
}]

resource lakehouseApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: lakehouseApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(commonApiPolicy, '__ALLOWED_CLIENT_IDS__', join(lakehouseClientIds, ','))
  }
  dependsOn: [
    namedValues
  ]
}

resource dataAgentApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: dataAgentApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(commonApiPolicy, '__ALLOWED_CLIENT_IDS__', join(dataAgentClientIds, ','))
  }
  dependsOn: [
    namedValues
  ]
}

resource tokenomicsApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: tokenomicsApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(commonApiPolicy, '__ALLOWED_CLIENT_IDS__', join(tokenomicsClientIds, ','))
  }
  dependsOn: [
    namedValues
  ]
}

resource lakehouseQueryOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: lakehouseApi
  name: 'query'
}

resource lakehouseTablesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: lakehouseApi
  name: 'tables'
}

resource lakehouseKnowledgeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: lakehouseApi
  name: 'knowledge'
}

resource dataAgentQueryOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: dataAgentApi
  name: 'query'
}

resource tokenomicsSummaryOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: tokenomicsApi
  name: 'summary'
}

resource lakehouseQueryPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: lakehouseQueryOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim/policies/lakehouse-query-operation-policy.xml')
  }
}

resource lakehouseTablesPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: lakehouseTablesOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim/policies/lakehouse-tables-operation-policy.xml')
  }
}

resource lakehouseKnowledgePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: lakehouseKnowledgeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim/policies/lakehouse-knowledge-operation-policy.xml')
  }
}

resource dataAgentQueryPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: dataAgentQueryOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim/policies/data-agent-query-operation-policy.xml')
  }
}

resource tokenomicsSummaryPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: tokenomicsSummaryOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim/policies/tokenomics-summary-operation-policy.xml')
  }
}

resource lakehouseMcp 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: lakehouseMcpId
  properties: any({
    type: 'mcp'
    displayName: lakehouseMcpDisplayName
    description: 'MCP tools for the Fabric Lakehouse OAuth API.'
    path: lakehouseMcpPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    mcpTools: [
      {
        name: 'query'
        operationId: lakehouseQueryOperation.id
      }
      {
        name: 'tables'
        operationId: lakehouseTablesOperation.id
      }
    ]
  })
  dependsOn: [
    lakehouseQueryPolicy
    lakehouseTablesPolicy
  ]
}

resource dataAgentMcp 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: dataAgentMcpId
  properties: any({
    type: 'mcp'
    displayName: dataAgentMcpDisplayName
    description: 'MCP tool for the Fabric Data Agent OAuth API.'
    path: dataAgentMcpPath
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    mcpTools: [
      {
        name: 'query'
        operationId: dataAgentQueryOperation.id
      }
    ]
  })
  dependsOn: [
    dataAgentQueryPolicy
  ]
}

resource fabricProduct 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: fabricProductId
  properties: {
    displayName: 'fabric'
    description: 'Delegated Fabric Lakehouse and Data Agent REST APIs, MCP servers, and CostOps telemetry.'
    subscriptionRequired: false
    state: 'published'
  }
}

resource foundryProduct 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: foundryProductId
  properties: {
    displayName: 'foundry'
    description: 'Managed-identity Microsoft Foundry model inference APIs governed by APIM AI Gateway policies.'
    subscriptionRequired: false
    state: 'published'
  }
}

var fabricProductApis = [
  { name: 'link-${lakehouseApiId}', apiId: lakehouseApi.id }
  { name: 'link-${dataAgentApiId}', apiId: dataAgentApi.id }
  { name: 'link-${lakehouseMcpId}', apiId: lakehouseMcp.id }
  { name: 'link-${dataAgentMcpId}', apiId: dataAgentMcp.id }
  { name: 'link-${tokenomicsApiId}', apiId: tokenomicsApi.id }
]

resource fabricProductApiLinks 'Microsoft.ApiManagement/service/products/apiLinks@2024-06-01-preview' = [for item in fabricProductApis: {
  parent: fabricProduct
  name: item.name
  properties: {
    apiId: item.apiId
  }
}]

resource foundryProductApiLinks 'Microsoft.ApiManagement/service/products/apiLinks@2024-06-01-preview' = [for (inferenceApi, index) in foundryInferenceApis: {
  parent: foundryProduct
  name: 'link-${inferenceApi.id}'
  properties: {
    apiId: foundryInferenceApi[index].id
  }
}]

resource insights 'Microsoft.Insights/components@2020-02-02' existing = if (diagnosticsEnabled) {
  scope: resourceGroup(applicationInsightsResourceGroupName)
  name: applicationInsightsName
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: apim
  name: loggerName
  properties: {
    loggerType: 'applicationInsights'
    credentials: {
      instrumentationKey: insights!.properties.InstrumentationKey
    }
    resourceId: insights!.id
    isBuffered: true
  }
}

resource tokenomicsDiagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (tokenomicsDiagnosticsEnabled) {
  name: 'fabric-tokenomics'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

var diagnosticProperties = {
  loggerId: resourceId('Microsoft.ApiManagement/service/loggers', apimServiceName, loggerName)
  alwaysLog: 'allErrors'
  sampling: {
    samplingType: 'fixed'
    percentage: 100
  }
  verbosity: 'information'
  logClientIp: false
  httpCorrelationProtocol: 'W3C'
  frontend: {
    request: { headers: [], body: { bytes: 0 } }
    response: { headers: [], body: { bytes: 0 } }
  }
  backend: {
    request: { headers: [], body: { bytes: 0 } }
    response: { headers: [], body: { bytes: 0 } }
  }
}

resource lakehouseDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: lakehouseApi
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
  ]
}

resource dataAgentDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: dataAgentApi
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
  ]
}

resource lakehouseMcpDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: lakehouseMcp
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
  ]
}

resource dataAgentMcpDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: dataAgentMcp
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
  ]
}

resource tokenomicsApiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (diagnosticsEnabled) {
  parent: tokenomicsApi
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
  ]
}

resource foundryInferenceDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = [for (inferenceApi, index) in foundryInferenceApis: if (diagnosticsEnabled) {
  parent: foundryInferenceApi[index]
  name: 'applicationinsights'
  properties: diagnosticProperties
  dependsOn: [
    logger
    foundryInferenceApiPolicy[index]
  ]
}]

output apimPrincipalId string = apim.identity.principalId
output lakehouseApiId string = lakehouseApi.id
output dataAgentApiId string = dataAgentApi.id
output lakehouseMcpId string = lakehouseMcp.id
output dataAgentMcpId string = dataAgentMcp.id
output tokenomicsApiId string = tokenomicsApi.id
output tokenomicsDiagnosticId string = tokenomicsDiagnosticsEnabled ? tokenomicsDiagnostic.id : ''
output foundryInferenceApiIds array = [for (inferenceApi, index) in foundryInferenceApis: foundryInferenceApi[index].id]
output fabricProductId string = fabricProduct.id
output foundryProductId string = foundryProduct.id
