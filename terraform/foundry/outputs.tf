output "account_id" {
  value       = azapi_resource.account.id
  description = "Private Microsoft Foundry account resource ID."
}

output "project_id" {
  value       = azapi_resource.project.id
  description = "Private Microsoft Foundry project resource ID."
}

output "project_endpoint" {
  value       = "https://${local.config.foundry.accountName}.services.ai.azure.com/api/projects/${local.config.foundry.projectName}"
  description = "Private Microsoft Foundry project endpoint."
}

output "project_principal_id" {
  value       = azapi_resource.project.output.identity.principalId
  description = "System-assigned managed identity object ID for the Foundry project."
}

output "model_connection_ids" {
  value       = { for key, connection in azapi_resource.model_connection : key => connection.id }
  description = "Per-agent APIM model connection resource IDs."
}