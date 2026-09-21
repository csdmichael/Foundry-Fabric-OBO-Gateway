terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azurecaf = {
      source  = "aztfmod/azurecaf"
      version = "~> 1.2.34"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = local.subscription_id
  tenant_id       = local.tenant_id
}

provider "azurecaf" {}