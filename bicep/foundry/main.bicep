targetScope = 'resourceGroup'

@description('Microsoft Foundry account name.')
@minLength(2)
@maxLength(64)
param accountName string

@description('Microsoft Foundry project name.')
@minLength(2)
@maxLength(64)
param projectName string

@description('Foundry and VNet region.')
param location string

@description('Existing VNet resource ID. The VNet must be in the Foundry region.')
param vnetResourceId string

@description('Exclusive subnet name for this Foundry account capability host.')
param agentSubnetName string

@description('CIDR for the exclusive Foundry agent subnet.')
param agentSubnetPrefix string

@description('Existing subnet resource ID used for Foundry private endpoints.')
param privateEndpointSubnetResourceId string

@description('Model deployment name and catalog model name.')
param modelName string

@description('Model provider format.')
param modelFormat string

@description('Pinned model version.')
param modelVersion string

@description('Model deployment SKU.')
param modelSkuName string

@description('Model deployment capacity in thousands of tokens per minute.')
@minValue(1)
param modelCapacity int

@description('System-assigned APIM principal that calls the private model backend.')
param apimPrincipalId string

@description('Current deployment principal that creates and validates prompt agents.')
param currentDeployerPrincipalId string

@description('Customer tags from the shared deployment configuration.')
param tags object = {}

var vnetParts = split(vnetResourceId, '/')
var vnetName = vnetParts[8]
var privateEndpointSubnetParts = split(privateEndpointSubnetResourceId, '/')
var privateEndpointSubnetName = privateEndpointSubnetParts[10]
var privateEndpointName = take('pe-${accountName}', 64)
var cognitiveServicesUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
var foundryProjectManagerRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'eadc314b-1a2d-4efa-be10-5d325db5065e')

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: privateEndpointSubnetName
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: agentSubnetName
  properties: {
    addressPrefix: agentSubnetPrefix
    defaultOutboundAccess: false
    delegations: [
      {
        name: 'Microsoft.App/environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
}

#disable-next-line BCP036
resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    disableLocalAuth: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnet.id
        useMicrosoftManagedNetwork: false
      }
    ]
    publicNetworkAccess: 'Disabled'
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundryAccount
  name: modelName
  sku: {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    model: {
      format: modelFormat
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource foundryPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'account'
        properties: {
          groupIds: [
            'account'
          ]
          privateLinkServiceId: foundryAccount.id
        }
      }
    ]
    subnet: {
      id: privateEndpointSubnet.id
    }
  }
}

resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.cognitiveservices.azure.com'
}

resource openAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.openai.azure.com'
}

resource foundryPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: 'privatelink.services.ai.azure.com'
}

resource foundryPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: foundryPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cognitive-services'
        properties: {
          privateDnsZoneId: cognitiveServicesPrivateDnsZone.id
        }
      }
      {
        name: 'openai'
        properties: {
          privateDnsZoneId: openAiPrivateDnsZone.id
        }
      }
      {
        name: 'foundry'
        properties: {
          privateDnsZoneId: foundryPrivateDnsZone.id
        }
      }
    ]
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Private Fabric CostOps prompt agents governed by Azure API Management.'
    displayName: projectName
  }
  dependsOn: [
    foundryPrivateDnsZoneGroup
  ]
}

resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01' = {
  parent: project
  name: 'caphostproj'
  properties: any({
    capabilityHostKind: 'Agents'
  })
}

resource apimModelRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryAccount
  name: guid(foundryAccount.id, apimPrincipalId, cognitiveServicesUserRoleDefinitionId)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesUserRoleDefinitionId
  }
}

resource deployerProjectManagerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, currentDeployerPrincipalId, foundryProjectManagerRoleDefinitionId)
  properties: {
    principalId: currentDeployerPrincipalId
    roleDefinitionId: foundryProjectManagerRoleDefinitionId
  }
}

output accountId string = foundryAccount.id
output accountName string = foundryAccount.name
output modelDeploymentName string = modelDeployment.name
output projectEndpoint string = 'https://${foundryAccount.name}.services.ai.azure.com/api/projects/${project.name}'
output projectId string = project.id
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
output agentSubnetId string = agentSubnet.id
output privateEndpointId string = foundryPrivateEndpoint.id
