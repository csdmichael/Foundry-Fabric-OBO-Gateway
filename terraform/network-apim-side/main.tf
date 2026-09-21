locals {
  config = jsondecode(file(var.config_path))

  deployment_config        = local.config.apim
  remote_deployment_config = local.config.azure

  tenant_id           = trimspace(local.deployment_config.tenantId)
  subscription_id     = trimspace(local.deployment_config.subscriptionId)
  resource_group_name = trimspace(local.deployment_config.resourceGroup)

  local_vnet_resource_id        = trimspace(local.config.network.apimVnetResourceId)
  remote_vnet_resource_id       = trimspace(local.config.network.brokerVnetResourceId)
  local_vnet_resource_id_parts  = split("/", local.local_vnet_resource_id)
  remote_vnet_resource_id_parts = split("/", local.remote_vnet_resource_id)

  virtual_network_resource_id_pattern = "(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$"
  local_vnet_resource_id_is_valid     = can(regex(local.virtual_network_resource_id_pattern, local.local_vnet_resource_id))
  remote_vnet_resource_id_is_valid    = can(regex(local.virtual_network_resource_id_pattern, local.remote_vnet_resource_id))

  local_vnet_subscription_id     = try(local.local_vnet_resource_id_parts[2], "")
  local_vnet_resource_group_name = try(local.local_vnet_resource_id_parts[4], "")
  local_vnet_name                = try(local.local_vnet_resource_id_parts[8], "")
  remote_vnet_subscription_id    = try(local.remote_vnet_resource_id_parts[2], "")
  remote_vnet_resource_group_name = try(
    local.remote_vnet_resource_id_parts[4],
    ""
  )
  remote_vnet_name = try(local.remote_vnet_resource_id_parts[8], "")

  local_vnet_matches_configured_scope = (
    lower(local.local_vnet_subscription_id) == lower(local.subscription_id) &&
    lower(local.local_vnet_resource_group_name) == lower(local.resource_group_name)
  )
  remote_vnet_matches_configured_scope = (
    lower(local.remote_vnet_subscription_id) == lower(trimspace(local.remote_deployment_config.subscriptionId)) &&
    lower(local.remote_vnet_resource_group_name) == lower(trimspace(local.remote_deployment_config.resourceGroup))
  )

  peering_base_name = "peer-${substr(local.local_vnet_name, 0, min(length(local.local_vnet_name), 30))}-to-${substr(local.remote_vnet_name, 0, min(length(local.remote_vnet_name), 30))}"
}

data "azurecaf_name" "peering" {
  name          = local.peering_base_name
  resource_type = "azurerm_virtual_network_peering"
  passthrough   = true
}

resource "azurerm_virtual_network_peering" "this" {
  name                         = data.azurecaf_name.peering.result
  resource_group_name          = local.local_vnet_resource_group_name
  virtual_network_name         = local.local_vnet_name
  remote_virtual_network_id    = local.remote_vnet_resource_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false

  lifecycle {
    precondition {
      condition     = local.local_vnet_resource_id_is_valid
      error_message = "network.apimVnetResourceId must be a full Microsoft.Network/virtualNetworks resource ID."
    }
    precondition {
      condition     = local.remote_vnet_resource_id_is_valid
      error_message = "network.brokerVnetResourceId must be a full Microsoft.Network/virtualNetworks resource ID."
    }
    precondition {
      condition     = lower(local.local_vnet_resource_id) != lower(local.remote_vnet_resource_id)
      error_message = "The local and remote virtual network resource IDs must differ."
    }
    precondition {
      condition     = local.local_vnet_matches_configured_scope
      error_message = "network.apimVnetResourceId must belong to apim.subscriptionId and apim.resourceGroup."
    }
    precondition {
      condition     = local.remote_vnet_matches_configured_scope
      error_message = "network.brokerVnetResourceId must belong to azure.subscriptionId and azure.resourceGroup."
    }
  }
}