targetScope = 'resourceGroup'

@description('Existing Microsoft Foundry account name.')
param accountName string

@description('Existing Microsoft Foundry project name.')
param projectName string

@description('Existing private APIM gateway URL.')
param apimGatewayUrl string

@description('Per-agent connection settings containing connectionName, apiPath, and agentId.')
@minLength(2)
param connections array

@description('Model deployment name exposed by APIM.')
param modelName string

@description('Model provider format.')
param modelFormat string

@description('Pinned model version.')
param modelVersion string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource modelConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = [for connection in connections: {
  parent: project
  name: connection.connectionName
  properties: any({
    audience: 'https://cognitiveservices.azure.com'
    authType: 'ProjectManagedIdentity'
    category: 'ApiManagement'
    credentials: {}
    isSharedToAll: true
    metadata: {
      customHeaders: string({
        'x-foundry-agent-id': connection.agentId
      })
      deploymentInPath: 'true'
      inferenceAPIVersion: '2024-10-21'
      models: string([
        {
          name: modelName
          properties: {
            model: {
              format: modelFormat
              name: modelName
              version: modelVersion
            }
          }
        }
      ])
    }
    target: '${apimGatewayUrl}/${connection.apiPath}'
  })
}]

output connectionIds array = [for (connection, index) in connections: modelConnection[index].id]
output connectionNames array = [for connection in connections: connection.connectionName]
