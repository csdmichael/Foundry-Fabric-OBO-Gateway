output "function_url" {
  description = "Private Function App base URL when deploy_function is true."
  value       = var.deploy_function ? "https://${azurerm_windows_function_app.broker[0].default_hostname}" : null
}

output "function_private_endpoint_ip" {
  description = "Sites private endpoint IP when deploy_function is true."
  value       = var.deploy_function ? azurerm_private_endpoint.function[0].private_service_connection[0].private_ip_address : null
}

output "key_vault_name" {
  description = "Broker Key Vault name."
  value       = azurerm_key_vault.broker.name
}

output "storage_account_name" {
  description = "Identity-based Functions host storage account name."
  value       = azurerm_storage_account.broker.name
}

output "deployment_container_id" {
  description = "ARM resource ID of the private deployment-package container."
  value       = azapi_resource.deployment_container.id
}

output "package_blob_url" {
  description = "HTTPS URL used by WEBSITE_RUN_FROM_PACKAGE."
  value       = local.package_blob_url
}

output "application_insights_name" {
  description = "Workspace-based Application Insights name."
  value       = azurerm_application_insights.broker.name
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.broker.name
}

output "log_analytics_workspace_resource_id" {
  description = "Log Analytics workspace ARM resource ID."
  value       = azurerm_log_analytics_workspace.broker.id
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace customer ID used by the query API."
  value       = azurerm_log_analytics_workspace.broker.workspace_id
}
output "user_assigned_identity_principal_id" {
  description = "Broker UAMI principal (object) ID."
  value       = azurerm_user_assigned_identity.broker.principal_id
}

output "user_assigned_identity_client_id" {
  description = "Broker UAMI client ID."
  value       = azurerm_user_assigned_identity.broker.client_id
}