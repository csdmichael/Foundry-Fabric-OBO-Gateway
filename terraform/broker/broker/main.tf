locals {
  config = jsondecode(file(var.config_path))

  subscription_id = local.config.azure.subscriptionId
  tenant_id       = local.config.azure.tenantId
  resource_group  = local.config.azure.resourceGroup
  location        = local.config.azure.location

  function_app_name                     = local.config.broker.appName
  existing_plan_name                    = local.config.broker.existingPlanName
  broker_vnet_resource_id               = local.config.network.brokerVnetResourceId
  private_endpoint_subnet_id            = local.config.network.brokerPrivateEndpointSubnetResourceId
  integration_subnet_id                 = local.config.network.brokerIntegrationSubnetResourceId
  allowed_user_object_ids               = length(var.allowed_user_object_ids) > 0 ? var.allowed_user_object_ids : tolist(local.config.identity.allowedUserObjectIds)
  node_version                          = local.config.broker.runtime
  tags                                  = tomap(local.config.tags)
  unique_name_suffix                    = substr(md5("${local.subscription_id}/${local.resource_group}/${local.function_app_name}"), 0, 8)
  arm_guid_namespace                    = "11fb06fb-712d-4ddd-98c7-e71bbd588830"
  uuid_pattern                          = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
  web_private_dns_zone_name             = "privatelink.azurewebsites.net"
  blob_private_dns_zone_name            = "privatelink.blob.core.windows.net"
  table_private_dns_zone_name           = "privatelink.table.core.windows.net"
  vault_private_dns_zone_name           = "privatelink.vaultcore.azure.net"
  package_blob_url                      = "${azurerm_storage_account.broker.primary_blob_endpoint}${var.deployment_container_name}/${var.package_blob_name}"
  key_vault_secrets_user_role_id        = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
  key_vault_secrets_officer_role_id     = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
  storage_blob_data_contributor_role_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  log_analytics_reader_role_id          = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/73c42c96-874c-492b-b04d-ab87d138a893"

  actual_cost_role_definition_ids = {
    cost_management_reader = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/72fafb9e-0641-4937-9268-a91bfd8191a3"
    monitoring_reader      = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/43d0d8ad-25c7-4714-9337-8ba259a9fe05"
    reader                 = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
  }

  storage_role_definition_ids = {
    blob_data_owner        = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b"
    table_data_contributor = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3"
  }

  identity_key_vault_role_definition_ids = {
    secrets_user = local.key_vault_secrets_user_role_id
  }

  private_endpoint_kinds = toset(["blob", "sites", "table", "vault"])
  private_dns_zones = {
    blob  = azurerm_private_dns_zone.blob.name
    sites = azurerm_private_dns_zone.web.name
    table = azurerm_private_dns_zone.table.name
    vault = azurerm_private_dns_zone.vault.name
  }
  existing_private_dns_vnet_link_names = {
    blob  = trimspace(local.config.network.brokerExistingPrivateDnsVnetLinks.blob)
    sites = trimspace(local.config.network.brokerExistingPrivateDnsVnetLinks.web)
    table = ""
    vault = ""
  }
  managed_private_dns_zones = {
    for kind, zone_name in local.private_dns_zones : kind => zone_name
    if local.existing_private_dns_vnet_link_names[kind] == ""
  }
}

data "azurerm_resource_group" "broker" {
  name = local.resource_group
}

data "azurerm_service_plan" "broker" {
  name                = local.existing_plan_name
  resource_group_name = data.azurerm_resource_group.broker.name
}

data "azurecaf_name" "identity" {
  name          = local.function_app_name
  resource_type = "azurerm_user_assigned_identity"
  suffixes      = [local.unique_name_suffix]
  clean_input   = true
}

data "azurecaf_name" "storage" {
  name          = local.function_app_name
  resource_type = "azurerm_storage_account"
  suffixes      = [local.unique_name_suffix]
  clean_input   = true
}

data "azurecaf_name" "key_vault" {
  name          = local.function_app_name
  resource_type = "azurerm_key_vault"
  suffixes      = [local.unique_name_suffix]
  clean_input   = true
}

data "azurecaf_name" "log_analytics" {
  name          = local.function_app_name
  resource_type = "azurerm_log_analytics_workspace"
  suffixes      = [local.unique_name_suffix]
  clean_input   = true
}

data "azurecaf_name" "application_insights" {
  name          = local.function_app_name
  resource_type = "azurerm_application_insights"
  suffixes      = [local.unique_name_suffix]
  clean_input   = true
}

data "azurecaf_name" "private_endpoint" {
  for_each = local.private_endpoint_kinds

  name          = local.function_app_name
  resource_type = "azurerm_private_endpoint"
  suffixes      = [each.key]
  clean_input   = true
}

data "azurecaf_name" "private_service_connection" {
  for_each = local.private_endpoint_kinds

  name          = local.function_app_name
  resource_type = "azurerm_private_service_connection"
  suffixes      = [each.key]
  clean_input   = true
}

data "azurecaf_name" "private_dns_link" {
  for_each = local.private_endpoint_kinds

  name          = local.function_app_name
  resource_type = "azurerm_private_dns_zone_virtual_network_link"
  suffixes      = [each.key]
  clean_input   = true
}

resource "azurerm_user_assigned_identity" "broker" {
  name                = data.azurecaf_name.identity.result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  tags                = local.tags
}

resource "azurerm_storage_account" "broker" {
  name                              = data.azurecaf_name.storage.result
  resource_group_name               = data.azurerm_resource_group.broker.name
  location                          = local.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  access_tier                       = "Hot"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  default_to_oauth_authentication   = true
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = false
  is_hns_enabled                    = false
  local_user_enabled                = false
  min_tls_version                   = "TLS1_2"
  nfsv3_enabled                     = false
  public_network_access_enabled     = false
  sftp_enabled                      = false
  shared_access_key_enabled         = false
  tags                              = local.tags

  blob_properties {
    container_delete_retention_policy {
      days = var.blob_delete_retention_days
    }

    delete_retention_policy {
      days                     = var.blob_delete_retention_days
      permanent_delete_enabled = false
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
  }
}

resource "azapi_resource" "deployment_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = var.deployment_container_name
  parent_id = "${azurerm_storage_account.broker.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azurerm_key_vault" "broker" {
  name                            = data.azurecaf_name.key_vault.result
  location                        = local.location
  resource_group_name             = data.azurerm_resource_group.broker.name
  tenant_id                       = local.tenant_id
  sku_name                        = "standard"
  rbac_authorization_enabled      = true
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false
  public_network_access_enabled   = false
  purge_protection_enabled        = true
  soft_delete_retention_days      = 90
  tags                            = local.tags
}

resource "azurerm_log_analytics_workspace" "broker" {
  name                       = data.azurecaf_name.log_analytics.result
  location                   = local.location
  resource_group_name        = data.azurerm_resource_group.broker.name
  sku                        = "PerGB2018"
  retention_in_days          = var.log_retention_days
  internet_ingestion_enabled = true
  internet_query_enabled     = true
  tags                       = local.tags
}

resource "azurerm_application_insights" "broker" {
  name                = data.azurecaf_name.application_insights.result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  workspace_id        = azurerm_log_analytics_workspace.broker.id
  application_type    = "web"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_role_assignment" "storage" {
  for_each = local.storage_role_definition_ids

  name               = uuidv5(local.arm_guid_namespace, "${azurerm_storage_account.broker.id}-${azurerm_user_assigned_identity.broker.id}-${each.value}")
  scope              = azurerm_storage_account.broker.id
  role_definition_id = each.value
  principal_id       = azurerm_user_assigned_identity.broker.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "identity_key_vault" {
  for_each = local.identity_key_vault_role_definition_ids

  name               = uuidv5(local.arm_guid_namespace, "${azurerm_key_vault.broker.id}-${azurerm_user_assigned_identity.broker.id}-${each.value}")
  scope              = azurerm_key_vault.broker.id
  role_definition_id = each.value
  principal_id       = azurerm_user_assigned_identity.broker.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployer_key_vault_secrets_officer" {
  name               = uuidv5(local.arm_guid_namespace, "${azurerm_key_vault.broker.id}-${var.current_deployer_principal_id}-${local.key_vault_secrets_officer_role_id}")
  scope              = azurerm_key_vault.broker.id
  role_definition_id = local.key_vault_secrets_officer_role_id
  principal_id       = var.current_deployer_principal_id
}

resource "azurerm_role_assignment" "deployer_storage_blob_data_contributor" {
  name               = uuidv5(local.arm_guid_namespace, "${azurerm_storage_account.broker.id}-${var.current_deployer_principal_id}-${local.storage_blob_data_contributor_role_id}")
  scope              = azurerm_storage_account.broker.id
  role_definition_id = local.storage_blob_data_contributor_role_id
  principal_id       = var.current_deployer_principal_id
}

resource "azurerm_role_assignment" "identity_log_analytics_reader" {
  name               = uuidv5(local.arm_guid_namespace, "${azurerm_log_analytics_workspace.broker.id}-${azurerm_user_assigned_identity.broker.id}-${local.log_analytics_reader_role_id}")
  scope              = azurerm_log_analytics_workspace.broker.id
  role_definition_id = local.log_analytics_reader_role_id
  principal_id       = azurerm_user_assigned_identity.broker.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "identity_actual_cost_readers" {
  for_each = local.config.tokenomics.actualCost.enabled ? local.actual_cost_role_definition_ids : {}

  name               = uuidv5(local.arm_guid_namespace, "${data.azurerm_resource_group.broker.id}-${azurerm_user_assigned_identity.broker.id}-${each.value}")
  scope              = data.azurerm_resource_group.broker.id
  role_definition_id = each.value
  principal_id       = azurerm_user_assigned_identity.broker.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_private_dns_zone" "web" {
  name                = local.web_private_dns_zone_name
  resource_group_name = data.azurerm_resource_group.broker.name
}

resource "azurerm_private_dns_zone" "blob" {
  name                = local.blob_private_dns_zone_name
  resource_group_name = data.azurerm_resource_group.broker.name
}

resource "azurerm_private_dns_zone" "table" {
  name                = local.table_private_dns_zone_name
  resource_group_name = data.azurerm_resource_group.broker.name
}

resource "azurerm_private_dns_zone" "vault" {
  name                = local.vault_private_dns_zone_name
  resource_group_name = data.azurerm_resource_group.broker.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "broker" {
  for_each = local.managed_private_dns_zones

  name                  = data.azurecaf_name.private_dns_link[each.key].result
  resource_group_name   = data.azurerm_resource_group.broker.name
  private_dns_zone_name = each.value
  virtual_network_id    = local.broker_vnet_resource_id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = data.azurecaf_name.private_endpoint["blob"].result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  subnet_id           = local.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = data.azurecaf_name.private_service_connection["blob"].result
    private_connection_resource_id = azurerm_storage_account.broker.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_private_endpoint" "table" {
  name                = data.azurecaf_name.private_endpoint["table"].result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  subnet_id           = local.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = data.azurecaf_name.private_service_connection["table"].result
    private_connection_resource_id = azurerm_storage_account.broker.id
    subresource_names              = ["table"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.table.id]
  }
}

resource "azurerm_private_endpoint" "vault" {
  name                = data.azurecaf_name.private_endpoint["vault"].result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  subnet_id           = local.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = data.azurecaf_name.private_service_connection["vault"].result
    private_connection_resource_id = azurerm_key_vault.broker.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.vault.id]
  }
}

resource "azurerm_windows_function_app" "broker" {
  count = var.deploy_function ? 1 : 0

  name                                           = local.function_app_name
  resource_group_name                            = data.azurerm_resource_group.broker.name
  location                                       = local.location
  service_plan_id                                = data.azurerm_service_plan.broker.id
  storage_account_name                           = azurerm_storage_account.broker.name
  storage_uses_managed_identity                  = true
  functions_extension_version                    = "~4"
  https_only                                     = true
  public_network_access_enabled                  = false
  virtual_network_subnet_id                      = local.integration_subnet_id
  key_vault_reference_identity_id                = azurerm_user_assigned_identity.broker.id
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  builtin_logging_enabled                        = false
  tags                                           = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.broker.id]
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME                     = "node"
    WEBSITE_NODE_DEFAULT_VERSION                 = "~22"
    WEBSITE_RUN_FROM_PACKAGE                     = local.package_blob_url
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = azurerm_user_assigned_identity.broker.id
    AzureWebJobsStorage__accountName             = azurerm_storage_account.broker.name
    AzureWebJobsStorage__credential              = "managedidentity"
    AzureWebJobsStorage__clientId                = azurerm_user_assigned_identity.broker.client_id
    APPLICATIONINSIGHTS_CONNECTION_STRING        = azurerm_application_insights.broker.connection_string
    RESOURCE_TENANT_ID                           = local.config.identity.resourceTenantId
    CALLER_TENANT_ID                             = local.config.identity.callerTenantId
    ENTRA_API_CLIENT_ID                          = var.entra_api_client_id
    OBO_CLIENT_SECRET                            = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.broker.vault_uri}secrets/${var.obo_client_secret_name})"
    BROKER_AUDIENCE                              = var.broker_audience
    BROKER_APPLICATION_ROLE                      = local.config.identity.brokerApplicationRole
    APIM_PRINCIPAL_ID                            = var.apim_principal_id
    ALLOWED_CONNECTOR_CLIENT_IDS                 = join(",", var.allowed_connector_client_ids)
    ALLOWED_USER_OBJECT_IDS                      = join(",", local.allowed_user_object_ids)
    DELEGATED_SCOPE                              = local.config.identity.delegatedScope
    FABRIC_API_SCOPE                             = local.config.identity.fabricApiScope
    POWER_BI_API_SCOPE                           = local.config.identity.powerBiApiScope
    FABRIC_WORKSPACE_ID                          = local.config.fabric.workspaceId
    FABRIC_LAKEHOUSE_NAME                        = local.config.fabric.lakehouseName
    FABRIC_SQL_ENDPOINT_HOST                     = local.config.fabric.sqlEndpointHost
    FABRIC_DATA_AGENT_ID                         = local.config.fabric.dataAgentId
    JWK_FETCH_TIMEOUT_MS                         = tostring(local.config.broker.jwkFetchTimeoutMs)
    TOKEN_EXCHANGE_TIMEOUT_MS                    = tostring(local.config.broker.tokenExchangeTimeoutMs)
    SQL_CONNECT_TIMEOUT_MS                       = tostring(local.config.broker.sqlConnectTimeoutMs)
    SQL_REQUEST_TIMEOUT_MS                       = tostring(local.config.broker.sqlRequestTimeoutMs)
    MAX_ROWS                                     = tostring(local.config.broker.maxRows)
    MAX_STATEMENT_LENGTH                         = tostring(local.config.broker.maxStatementLength)
    MANAGED_IDENTITY_CLIENT_ID                   = azurerm_user_assigned_identity.broker.client_id
    LOG_ANALYTICS_WORKSPACE_ID                   = azurerm_log_analytics_workspace.broker.workspace_id
    TOKENOMICS_APIM_API_IDS                      = join(",", [local.config.apim.lakehouseApiId, local.config.apim.dataAgentApiId, "${local.config.apim.lakehouseApiId}-mcp", "${local.config.apim.dataAgentApiId}-mcp", local.config.apim.inferenceApis.lakehouse.id, local.config.apim.inferenceApis.dataAgent.id])
    TOKENOMICS_API_ATTRIBUTION_JSON = jsonencode({
      (local.config.apim.inferenceApis.lakehouse.id) = local.config.foundry.agents.lakehouse
      (local.config.apim.inferenceApis.dataAgent.id) = local.config.foundry.agents.dataAgent
    })
    TOKENOMICS_PROJECT_ID              = local.config.tokenomics.projectId
    TOKENOMICS_TEAM_ID                 = local.config.tokenomics.teamId
    TOKENOMICS_COST_CENTER             = local.config.tokenomics.costCenter
    TOKENOMICS_CURRENCY                = local.config.tokenomics.currency
    TOKENOMICS_RATE_CARD_JSON          = jsonencode(local.config.tokenomics.rateCard)
    ACTUAL_COST_ENABLED                = tostring(local.config.tokenomics.actualCost.enabled)
    ACTUAL_COST_SCOPE                  = local.config.tokenomics.actualCost.scope
    ACTUAL_COST_QUERY_API_VERSION      = local.config.tokenomics.actualCost.queryApiVersion
    ACTUAL_COST_BILLING_LAG_HOURS      = tostring(local.config.tokenomics.actualCost.billingLagHours)
    ACTUAL_COST_TRACKED_RESOURCES_JSON = jsonencode(local.config.tokenomics.actualCost.trackedResources)
  }

  site_config {
    always_on                         = local.config.broker.alwaysOn
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    ip_restriction_default_action     = "Deny"
    minimum_tls_version               = "1.2"
    scm_ip_restriction_default_action = "Deny"
    scm_minimum_tls_version           = "1.2"
    scm_use_main_ip_restriction       = true
    use_32_bit_worker                 = false
    vnet_route_all_enabled            = true

    application_stack {
      node_version = local.node_version
    }
  }

  lifecycle {
    precondition {
      condition = (
        can(regex(local.uuid_pattern, var.entra_api_client_id)) &&
        can(regex(local.uuid_pattern, var.broker_audience)) &&
        can(regex(local.uuid_pattern, var.apim_principal_id)) &&
        length(var.allowed_connector_client_ids) > 0 &&
        alltrue([for id in var.allowed_connector_client_ids : can(regex(local.uuid_pattern, id))]) &&
        length(local.allowed_user_object_ids) > 0 &&
        alltrue([for id in local.allowed_user_object_ids : can(regex(local.uuid_pattern, id))])
      )
      error_message = "deploy_function=true requires valid generated Entra API, audience, and APIM UUIDs plus nonempty valid connector and user UUID allowlists."
    }

    precondition {
      condition     = data.azurerm_service_plan.broker.os_type == "Windows" && upper(data.azurerm_service_plan.broker.sku_name) == "B1"
      error_message = "broker.existingPlanName must identify the existing Windows B1 App Service plan."
    }

    precondition {
      condition     = local.node_version == "~22" && local.config.broker.alwaysOn
      error_message = "broker.runtime must select Node 22 and broker.alwaysOn must be true."
    }
  }

  depends_on = [
    azapi_resource.deployment_container,
    azurerm_private_dns_zone_virtual_network_link.broker,
    azurerm_private_endpoint.blob,
    azurerm_private_endpoint.table,
    azurerm_role_assignment.deployer_storage_blob_data_contributor,
    azurerm_role_assignment.identity_key_vault,
    azurerm_role_assignment.identity_log_analytics_reader,
    azurerm_role_assignment.identity_actual_cost_readers,
    azurerm_role_assignment.storage,
  ]
}

resource "azurerm_monitor_diagnostic_setting" "function" {
  count = var.deploy_function ? 1 : 0

  name                       = "function-logs"
  target_resource_id         = azurerm_windows_function_app.broker[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.broker.id

  enabled_log {
    category = "FunctionAppLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_private_endpoint" "function" {
  count = var.deploy_function ? 1 : 0

  name                = data.azurecaf_name.private_endpoint["sites"].result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.broker.name
  subnet_id           = local.private_endpoint_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = data.azurecaf_name.private_service_connection["sites"].result
    private_connection_resource_id = azurerm_windows_function_app.broker[0].id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.web.id]
  }
}