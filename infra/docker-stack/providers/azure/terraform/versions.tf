terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.16"
    }
  }

  # Uncomment and configure before first apply.
  # Pre-create the storage account and container for state manually or via a
  # bootstrap script — Terraform cannot manage its own backend storage.
  #
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "tfstate<unique_suffix>"
  #   container_name       = "tfstate"
  #   key                  = "docker-stack/azure/terraform.tfstate"
  # }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

data "azurerm_client_config" "current" {}

# Credentials are only used when enable_tailscale = true. Empty defaults are
# safe when Tailscale is disabled — the provider makes no API calls unless a
# tailscale_tailnet_key resource is being managed.
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
}
