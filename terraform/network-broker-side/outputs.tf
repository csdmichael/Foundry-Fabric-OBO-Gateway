output "peering_id" {
  description = "Resource ID of the broker-to-APIM VNet peering."
  value       = azurerm_virtual_network_peering.this.id
}

output "peering_name" {
  description = "Name of the broker-to-APIM VNet peering used for state inspection."
  value       = azurerm_virtual_network_peering.this.name
}

output "local_virtual_network_name" {
  description = "Broker VNet name parsed from network.brokerVnetResourceId."
  value       = local.local_vnet_name
}

output "local_resource_group_name" {
  description = "Broker resource group parsed from network.brokerVnetResourceId."
  value       = local.local_vnet_resource_group_name
}

output "remote_virtual_network_id" {
  description = "APIM VNet resource ID configured as the remote peering target."
  value       = azurerm_virtual_network_peering.this.remote_virtual_network_id
}

output "remote_virtual_network_name" {
  description = "APIM VNet name parsed from network.apimVnetResourceId."
  value       = local.remote_vnet_name
}