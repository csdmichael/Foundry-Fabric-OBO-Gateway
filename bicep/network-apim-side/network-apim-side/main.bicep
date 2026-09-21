targetScope = 'resourceGroup'

var config = loadJsonContent('../../config/deployment.json')
var deploymentConfig = config.apim
var remoteDeploymentConfig = config.azure
var networkConfig = config.network

var localVnetResourceId = trim(string(networkConfig.apimVnetResourceId))
var remoteVnetResourceId = trim(string(networkConfig.brokerVnetResourceId))
var localVnetResourceIdParts = split(localVnetResourceId, '/')
var remoteVnetResourceIdParts = split(remoteVnetResourceId, '/')

var localVnetResourceIdHasExpectedShape = length(localVnetResourceIdParts) == 9 && localVnetResourceIdParts[0] == '' && toLower(localVnetResourceIdParts[1]) == 'subscriptions' && !empty(localVnetResourceIdParts[2]) && toLower(localVnetResourceIdParts[3]) == 'resourcegroups' && !empty(localVnetResourceIdParts[4]) && toLower(localVnetResourceIdParts[5]) == 'providers' && toLower(localVnetResourceIdParts[6]) == 'microsoft.network' && toLower(localVnetResourceIdParts[7]) == 'virtualnetworks' && !empty(localVnetResourceIdParts[8])
var remoteVnetResourceIdHasExpectedShape = length(remoteVnetResourceIdParts) == 9 && remoteVnetResourceIdParts[0] == '' && toLower(remoteVnetResourceIdParts[1]) == 'subscriptions' && !empty(remoteVnetResourceIdParts[2]) && toLower(remoteVnetResourceIdParts[3]) == 'resourcegroups' && !empty(remoteVnetResourceIdParts[4]) && toLower(remoteVnetResourceIdParts[5]) == 'providers' && toLower(remoteVnetResourceIdParts[6]) == 'microsoft.network' && toLower(remoteVnetResourceIdParts[7]) == 'virtualnetworks' && !empty(remoteVnetResourceIdParts[8])
var validatedLocalVnetResourceId = localVnetResourceIdHasExpectedShape ? localVnetResourceId : fail('network.apimVnetResourceId must be a full Microsoft.Network/virtualNetworks resource ID.')
var validatedRemoteVnetResourceId = remoteVnetResourceIdHasExpectedShape ? remoteVnetResourceId : fail('network.brokerVnetResourceId must be a full Microsoft.Network/virtualNetworks resource ID.')
var validatedLocalVnetResourceIdParts = split(validatedLocalVnetResourceId, '/')
var validatedRemoteVnetResourceIdParts = split(validatedRemoteVnetResourceId, '/')
var distinctRemoteVnetResourceId = toLower(validatedLocalVnetResourceId) != toLower(validatedRemoteVnetResourceId) ? validatedRemoteVnetResourceId : fail('The local and remote virtual network resource IDs must differ.')
var localVnetMatchesConfiguredScope = toLower(validatedLocalVnetResourceIdParts[2]) == toLower(string(deploymentConfig.subscriptionId)) && toLower(validatedLocalVnetResourceIdParts[4]) == toLower(string(deploymentConfig.resourceGroup))
var scopedLocalVnetResourceId = localVnetMatchesConfiguredScope ? validatedLocalVnetResourceId : fail('network.apimVnetResourceId must belong to apim.subscriptionId and apim.resourceGroup.')
var remoteVnetMatchesConfiguredScope = toLower(validatedRemoteVnetResourceIdParts[2]) == toLower(string(remoteDeploymentConfig.subscriptionId)) && toLower(validatedRemoteVnetResourceIdParts[4]) == toLower(string(remoteDeploymentConfig.resourceGroup))
var configuredRemoteVnetResourceId = remoteVnetMatchesConfiguredScope ? distinctRemoteVnetResourceId : fail('network.brokerVnetResourceId must belong to azure.subscriptionId and azure.resourceGroup.')
var deploymentMatchesConfiguredScope = toLower(tenant().tenantId) == toLower(string(deploymentConfig.tenantId)) && toLower(subscription().subscriptionId) == toLower(string(deploymentConfig.subscriptionId)) && toLower(resourceGroup().name) == toLower(string(deploymentConfig.resourceGroup))
var scopedRemoteVnetResourceId = deploymentMatchesConfiguredScope ? configuredRemoteVnetResourceId : fail('Deploy this template only in the tenant, subscription, and resource group configured under apim.')

var localVnetName = split(scopedLocalVnetResourceId, '/')[8]
var remoteVnetName = split(scopedRemoteVnetResourceId, '/')[8]
var peeringName = 'peer-${take(localVnetName, 30)}-to-${take(remoteVnetName, 30)}'

resource localVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    allowForwardedTraffic: true
    allowGatewayTransit: false
    allowVirtualNetworkAccess: true
    remoteVirtualNetwork: {
      id: scopedRemoteVnetResourceId
    }
    useRemoteGateways: false
  }
}

output peeringId string = peering.id
output peeringName string = peeringName
output localVirtualNetworkName string = localVnetName
output localResourceGroupName string = validatedLocalVnetResourceIdParts[4]
output remoteVirtualNetworkId string = scopedRemoteVnetResourceId
output remoteVirtualNetworkName string = remoteVnetName
