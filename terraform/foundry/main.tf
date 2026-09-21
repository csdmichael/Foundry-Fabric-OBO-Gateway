locals {
  config          = jsondecode(file(var.config_path))
  subscription_id = local.config.azure.subscriptionId
  tenant_id       = local.config.azure.tenantId
  resource_group  = local.config.azure.resourceGroup
  location        = local.config.foundry.location
  tags            = tomap(local.config.tags)
  vnet_parts      = split("/", local.config.foundry.vnetResourceId)
  vnet_name       = local.vnet_parts[8]
  arm_namespace   = "11fb06fb-712d-4ddd-98c7-e71bbd588830"

  cognitive_services_user_role_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
  foundry_project_manager_role_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/eadc314b-1a2d-4efa-be10-5d325db5065e"

  model_connections = {
    lakehouse = {
      name     = local.config.foundry.modelConnections.lakehouse
      api_path = local.config.apim.inferenceApis.lakehouse.path
      agent_id = local.config.foundry.agents.lakehouse
    }
    data_agent = {
      name     = local.config.foundry.modelConnections.dataAgent
      api_path = local.config.apim.inferenceApis.dataAgent.path
      agent_id = local.config.foundry.agents.dataAgent
    }
  }
}

data "azurerm_resource_group" "foundry" {
  name = local.resource_group
}

resource "azurerm_subnet" "agent" {
  name                            = local.config.foundry.agentSubnetName
  resource_group_name             = local.resource_group
  virtual_network_name            = local.vnet_name
  address_prefixes                = [local.config.foundry.agentSubnetPrefix]
  default_outbound_access_enabled = false

  delegation {
    name = "Microsoft.App/environments"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azapi_resource" "account" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name                      = local.config.foundry.accountName
  parent_id                 = data.azurerm_resource_group.foundry.id
  location                  = local.location
  tags                      = local.tags
  schema_validation_enabled = false
  response_export_values    = ["identity.principalId", "properties.endpoint"]

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.config.foundry.accountName
      disableLocalAuth       = true
      networkAcls = {
        bypass              = "AzureServices"
        defaultAction       = "Deny"
        ipRules             = []
        virtualNetworkRules = []
      }
      networkInjections = [{
        scenario                   = "agent"
        subnetArmId                = azurerm_subnet.agent.id
        useMicrosoftManagedNetwork = false
      }]
      publicNetworkAccess = "Disabled"
    }
  }
}

resource "azapi_resource" "model" {
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-06-01"
  name                      = local.config.foundry.model.name
  parent_id                 = azapi_resource.account.id
  schema_validation_enabled = false

  body = {
    sku = {
      capacity = local.config.foundry.model.capacity
      name     = local.config.foundry.model.skuName
    }
    properties = {
      model = {
        format  = local.config.foundry.model.format
        name    = local.config.foundry.model.name
        version = local.config.foundry.model.version
      }
      versionUpgradeOption = "NoAutoUpgrade"
    }
  }
}

resource "azapi_resource" "project" {
  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name                      = local.config.foundry.projectName
  parent_id                 = azapi_resource.account.id
  location                  = local.location
  tags                      = local.tags
  schema_validation_enabled = false
  response_export_values    = ["identity.principalId", "properties.endpoints"]

  body = {
    identity = {
      type = "SystemAssigned"
    }
    properties = {
      description = "Private Fabric CostOps prompt agents governed by Azure API Management."
      displayName = local.config.foundry.projectName
    }
  }
}

resource "azapi_resource" "project_capability_host" {
  type                      = "Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-06-01"
  name                      = "caphostproj"
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind = "Agents"
    }
  }
}

data "azurerm_private_dns_zone" "cognitive_services" {
  name                = "privatelink.cognitiveservices.azure.com"
  resource_group_name = local.resource_group
}

data "azurerm_private_dns_zone" "openai" {
  name                = "privatelink.openai.azure.com"
  resource_group_name = local.resource_group
}

data "azurerm_private_dns_zone" "foundry" {
  name                = "privatelink.services.ai.azure.com"
  resource_group_name = local.resource_group
}

resource "azurerm_private_endpoint" "foundry" {
  name                = substr("pe-${local.config.foundry.accountName}", 0, 64)
  location            = local.location
  resource_group_name = local.resource_group
  subnet_id           = local.config.foundry.privateEndpointSubnetResourceId
  tags                = local.tags

  private_service_connection {
    name                           = "account"
    private_connection_resource_id = azapi_resource.account.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      data.azurerm_private_dns_zone.cognitive_services.id,
      data.azurerm_private_dns_zone.openai.id,
      data.azurerm_private_dns_zone.foundry.id,
    ]
  }
}

resource "azurerm_role_assignment" "apim_model_user" {
  name               = uuidv5(local.arm_namespace, "${azapi_resource.account.id}-${var.apim_principal_id}-${local.cognitive_services_user_role_id}")
  scope              = azapi_resource.account.id
  role_definition_id = local.cognitive_services_user_role_id
  principal_id       = var.apim_principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployer_project_manager" {
  name               = uuidv5(local.arm_namespace, "${azapi_resource.project.id}-${var.current_deployer_principal_id}-${local.foundry_project_manager_role_id}")
  scope              = azapi_resource.project.id
  role_definition_id = local.foundry_project_manager_role_id
  principal_id       = var.current_deployer_principal_id
}

resource "azapi_resource" "model_connection" {
  for_each = local.model_connections

  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview"
  name                      = each.value.name
  parent_id                 = azapi_resource.project.id
  schema_validation_enabled = false

  body = {
    properties = {
      audience      = "https://cognitiveservices.azure.com"
      authType      = "ProjectManagedIdentity"
      category      = "ApiManagement"
      credentials   = {}
      isSharedToAll = true
      metadata = {
        customHeaders       = jsonencode({ "x-foundry-agent-id" = each.value.agent_id })
        deploymentInPath    = "true"
        inferenceAPIVersion = "2024-10-21"
        models = jsonencode([{
          name = local.config.foundry.model.name
          properties = {
            model = {
              format  = local.config.foundry.model.format
              name    = local.config.foundry.model.name
              version = local.config.foundry.model.version
            }
          }
        }])
      }
      target = "${local.config.apim.gatewayUrl}/${each.value.api_path}"
    }
  }

  depends_on = [
    azapi_resource.project_capability_host,
  ]
}