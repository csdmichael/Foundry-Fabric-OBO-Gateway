variable "config_path" {
  description = "Path to the Fabric deployment configuration file."
  type        = string
  default     = "../../config/deployment.json"
}

variable "resource_api_client_id" {
  description = "Generated client ID of the Fabric resource API application registration."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$", trimspace(var.resource_api_client_id)))
    error_message = "resource_api_client_id must be a nonempty GUID."
  }
}

variable "api_client_ids" {
  description = "Generated application client IDs allowed to call each delegated API surface."
  type = object({
    lakehouse  = list(string)
    data_agent = list(string)
    tokenomics = list(string)
  })

  validation {
    condition = alltrue([
      for values in [var.api_client_ids.lakehouse, var.api_client_ids.data_agent, var.api_client_ids.tokenomics] :
      length(values) > 0 && alltrue([
        for value in values : can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$", trimspace(value)))
      ])
    ])
    error_message = "api_client_ids must contain at least one nonempty GUID for lakehouse, data_agent, and tokenomics."
  }
}

variable "allowed_user_object_ids" {
  description = "Fabric-tenant user object IDs allowed to call the APIs."
  type        = list(string)

  validation {
    condition = length(var.allowed_user_object_ids) > 0 && alltrue([
      for value in var.allowed_user_object_ids : can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$", trimspace(value)))
    ])
    error_message = "allowed_user_object_ids must contain at least one nonempty GUID."
  }
}

variable "broker_audience" {
  description = "Generated application client ID used as the private broker audience."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$", trimspace(var.broker_audience)))
    error_message = "broker_audience must be a nonempty GUID."
  }
}

variable "foundry_project_mi_client_id" {
  description = "Application client ID of the Foundry project system-assigned managed identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$", trimspace(var.foundry_project_mi_client_id)))
    error_message = "foundry_project_mi_client_id must be a nonempty GUID."
  }
}

variable "broker_private_url" {
  description = "Fixed private broker origin, without an /api path."
  type        = string

  validation {
    condition     = can(regex("^https://[A-Za-z0-9-]+\\.azurewebsites\\.net/?$", trimspace(var.broker_private_url)))
    error_message = "broker_private_url must be a nonempty HTTPS azurewebsites.net origin."
  }
}

variable "application_insights_name" {
  description = "Optional existing Application Insights component name. Diagnostics are omitted when null or empty."
  type        = string
  default     = null
  nullable    = true
}

variable "application_insights_resource_group_name" {
  description = "Optional resource group of the existing Application Insights component. Defaults to config.apim.resourceGroup."
  type        = string
  default     = null
  nullable    = true
}

variable "log_analytics_workspace_id" {
  description = "Optional existing Log Analytics workspace ARM resource ID for APIM gateway and LLM diagnostics."
  type        = string
  default     = null
  nullable    = true
}
