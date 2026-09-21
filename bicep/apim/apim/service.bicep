targetScope = 'resourceGroup'

@description('APIM region. Must match the existing VNet region.')
param location string

@description('Globally unique API Management service name.')
param apimServiceName string

@description('API Management publisher email.')
param publisherEmail string

@description('API Management publisher name.')
param publisherName string

@allowed([
  'Enabled'
  'Disabled'
])
@description('Whether the API Management public network endpoint is enabled.')
param publicNetworkAccess string = 'Disabled'

@allowed([
  'Developer'
  'Premium'
])
param skuName string = 'Developer'

@description('Existing VNet resource ID that also hosts the broker integration and private endpoints.')
param vnetResourceId string

@description('Dedicated APIM subnet name without delegation.')
param subnetName string

@description('Dedicated APIM subnet CIDR.')
param subnetPrefix string

param tags object = {}

var vnetParts = split(vnetResourceId, '/')
var validVnetId = length(vnetParts) == 9 && vnetParts[0] == '' && toLower(vnetParts[1]) == 'subscriptions' && toLower(vnetParts[3]) == 'resourcegroups' && toLower(vnetParts[5]) == 'providers' && toLower(vnetParts[6]) == 'microsoft.network' && toLower(vnetParts[7]) == 'virtualnetworks'
var validatedVnetId = validVnetId ? vnetResourceId : fail('vnetResourceId must be a full Microsoft.Network/virtualNetworks resource ID.')
var validatedVnetParts = split(validatedVnetId, '/')
var sameScope = toLower(validatedVnetParts[2]) == toLower(subscription().subscriptionId) && toLower(validatedVnetParts[4]) == toLower(resourceGroup().name)
var scopedVnetId = sameScope ? validatedVnetId : fail('The dedicated APIM VNet must be in the deployment subscription and resource group.')
var vnetName = last(split(scopedVnetId, '/'))

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${apimServiceName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Internet-Client'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-ApiManagement-ControlPlane'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-AzureTrafficManager'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureTrafficManager'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Allow-Certificate-Validation'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Internet'
        }
      }
      {
        name: 'Allow-Storage'
        properties: {
          priority: 210
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
        }
      }
      {
        name: 'Allow-Sql'
        properties: {
          priority: 220
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Sql'
        }
      }
      {
        name: 'Allow-KeyVault'
        properties: {
          priority: 230
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureKeyVault'
        }
      }
      {
        name: 'Allow-AzureMonitor'
        properties: {
          priority: 240
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '1886'
            '443'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureMonitor'
        }
      }
      {
        name: 'Allow-AzureActiveDirectory'
        properties: {
          priority: 250
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureActiveDirectory'
        }
      }
    ]
  }
}

resource apimSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: subnetPrefix
    delegations: []
    networkSecurityGroup: {
      id: apimNsg.id
    }
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
    serviceEndpoints: [
      { service: 'Microsoft.Storage' }
      { service: 'Microsoft.Sql' }
      { service: 'Microsoft.KeyVault' }
      { service: 'Microsoft.EventHub' }
    ]
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: publicNetworkAccess
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnet.id
    }
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
    }
  }
}

output apimId string = apim.id
output apimPrincipalId string = apim.identity.principalId
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimSubnetId string = apimSubnet.id
output apimNsgId string = apimNsg.id
