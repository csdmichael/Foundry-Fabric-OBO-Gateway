variable "config_path" {
  description = "Path to the shared Fabric deployment configuration JSON file."
  type        = string
  default     = "../../config/deployment.json"

  validation {
    condition     = fileexists(var.config_path)
    error_message = "config_path must point to an existing deployment.json file."
  }
}

variable "deploy_function" {
  description = "Deploy the Function App after generated identity values and allowlists are ready."
  type        = bool
  default     = false
}

variable "entra_api_client_id" {
  description = "Generated client ID of the Fabric-tenant broker API app registration."
  type        = string
  default     = ""
}

variable "broker_audience" {
  description = "Generated v2 access-token audience GUID."
  type        = string
  default     = ""
}

variable "apim_principal_id" {
  description = "Generated object ID of the APIM managed identity in the caller tenant."
  type        = string
  default     = ""
}

variable "allowed_connector_client_ids" {
  description = "Generated connector application client IDs allowed to call the broker."
  type        = list(string)
  default     = []
}

variable "allowed_user_object_ids" {
  description = "Optional override for identity.allowedUserObjectIds in deployment.json."
  type        = list(string)
  default     = []
}

variable "current_deployer_principal_id" {
  description = "Object ID of the current deployment principal that receives Key Vault Secrets Officer and Storage Blob Data Contributor."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", var.current_deployer_principal_id))
    error_message = "current_deployer_principal_id must be a UUID."
  }
}

variable "deployment_container_name" {
  description = "Private blob container used for Function deployment packages."
  type        = string
  default     = "deployments"

  validation {
    condition = (
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.deployment_container_name)) &&
      !strcontains(var.deployment_container_name, "--")
    )
    error_message = "deployment_container_name must be a valid 3-63 character lowercase blob container name."
  }
}

variable "package_blob_name" {
  description = "Blob name of the Function deployment package."
  type        = string
  default     = "fabric-obo-broker.zip"

  validation {
    condition = (
      can(regex("^[0-9A-Za-z][0-9A-Za-z._-]*$", var.package_blob_name)) &&
      length(var.package_blob_name) <= 1024
    )
    error_message = "package_blob_name must be a nonempty URL-safe blob name of at most 1024 characters."
  }
}

variable "obo_client_secret_name" {
  description = "Versionless Key Vault secret name containing the OBO application credential. No secret value is accepted by this module."
  type        = string
  default     = "obo-client-secret"

  validation {
    condition     = can(regex("^[0-9A-Za-z-]{1,127}$", var.obo_client_secret_name))
    error_message = "obo_client_secret_name must be a valid Key Vault secret name."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "blob_delete_retention_days" {
  description = "Blob and container soft-delete retention in days."
  type        = number
  default     = 7

  validation {
    condition     = var.blob_delete_retention_days >= 1 && var.blob_delete_retention_days <= 365
    error_message = "blob_delete_retention_days must be between 1 and 365."
  }
}