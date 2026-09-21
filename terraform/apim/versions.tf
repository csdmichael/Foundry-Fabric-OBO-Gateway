terraform {
  required_version = ">= 1.5.0"

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

  subscription_id = local.apim_subscription_id
  tenant_id       = local.apim_tenant_id
}

provider "azapi" {
  subscription_id = local.apim_subscription_id
  tenant_id       = local.apim_tenant_id
}