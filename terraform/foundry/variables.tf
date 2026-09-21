variable "config_path" {
  description = "Path to the shared Fabric deployment configuration JSON file."
  type        = string
  default     = "../../config/deployment.json"

  validation {
    condition     = fileexists(var.config_path)
    error_message = "config_path must point to an existing deployment.json file."
  }
}

variable "apim_principal_id" {
  description = "Object ID of the existing APIM system-assigned managed identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.apim_principal_id))
    error_message = "apim_principal_id must be a UUID."
  }
}

variable "current_deployer_principal_id" {
  description = "Object ID of the principal that provisions and validates Prompt Agents."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.current_deployer_principal_id))
    error_message = "current_deployer_principal_id must be a UUID."
  }
}