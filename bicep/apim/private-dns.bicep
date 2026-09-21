targetScope = 'resourceGroup'

param brokerAppName string
@minLength(7)
@maxLength(15)
param brokerPrivateEndpointIp string
param apimServiceName string
@minLength(1)
param apimVnetResourceId string
param tags object

var privateDnsZoneName = 'privatelink.azurewebsites.net'

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: privateDnsZoneName
}

resource brokerRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: brokerAppName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: brokerPrivateEndpointIp
      }
    ]
  }
}

resource brokerScmRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: '${brokerAppName}.scm'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: brokerPrivateEndpointIp
      }
    ]
  }
}

resource apimVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: '${apimServiceName}-broker'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: apimVnetResourceId
    }
  }
}

output privateDnsZoneId string = privateDnsZone.id
