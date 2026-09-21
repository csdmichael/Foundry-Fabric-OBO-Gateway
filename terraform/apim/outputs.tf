output "apim_principal_id" {
  description = "System-assigned managed identity principal ID that must receive the broker application role."
  value       = local.apim_principal_id
}

output "lakehouse_api_url" {
  description = "Fabric Lakehouse OAuth REST API URL."
  value       = "${local.apim_gateway_url}/${local.config.apim.lakehouseApiPath}"
}

output "data_agent_api_url" {
  description = "Fabric Data Agent OAuth REST API URL."
  value       = "${local.apim_gateway_url}/${local.config.apim.dataAgentApiPath}"
}

output "lakehouse_mcp_url" {
  description = "Fabric Lakehouse MCP endpoint."
  value       = "${local.apim_gateway_url}/${local.config.apim.lakehouseMcpPath}/mcp"
}

output "data_agent_mcp_url" {
  description = "Fabric Data Agent MCP endpoint."
  value       = "${local.apim_gateway_url}/${local.config.apim.dataAgentMcpPath}/mcp"
}

output "tokenomics_api_url" {
  description = "Fabric tokenomics dashboard API URL."
  value       = "${local.apim_gateway_url}/${local.config.apim.tokenomicsApiPath}"
}

output "lakehouse_inference_url" {
  description = "Lakehouse Prompt Agent managed-identity inference API URL."
  value       = "${local.apim_gateway_url}/${local.config.apim.inferenceApis.lakehouse.path}"
}

output "data_agent_inference_url" {
  description = "Data Agent Prompt Agent managed-identity inference API URL."
  value       = "${local.apim_gateway_url}/${local.config.apim.inferenceApis.dataAgent.path}"
}
output "fabric_product_id" {
  description = "Resource ID of the published fabric APIM product."
  value       = azapi_resource.product["fabric"].id
}

output "foundry_product_id" {
  description = "Resource ID of the published foundry APIM product."
  value       = azapi_resource.product["foundry"].id
}
