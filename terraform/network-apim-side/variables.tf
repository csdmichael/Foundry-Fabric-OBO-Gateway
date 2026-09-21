variable "config_path" {
  description = "Path to the shared Fabric deployment configuration JSON file."
  type        = string
  default     = "../../config/deployment.json"

  validation {
    condition     = fileexists(var.config_path)
    error_message = "config_path must point to an existing deployment.json file."
  }
}