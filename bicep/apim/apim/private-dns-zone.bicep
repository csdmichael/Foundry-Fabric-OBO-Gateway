targetScope = 'resourceGroup'

param tags object

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}

output privateDnsZoneId string = privateDnsZone.id
