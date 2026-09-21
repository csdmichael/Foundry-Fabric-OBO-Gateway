terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = local.subscription_id
  tenant_id       = local.tenant_id
}

provider "azapi" {
  subscription_id  = local.subscription_id
  tenant_id        = local.tenant_id
  enable_preflight = true
}