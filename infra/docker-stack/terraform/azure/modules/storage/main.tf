resource "random_string" "sa_suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  # Storage account names: 3-24 chars, lowercase letters and numbers only.
  # Strip hyphens from the prefix, truncate to 18 chars, append 6 random chars.
  sa_name = "${lower(replace(substr(var.name_prefix, 0, 18), "-", ""))}${random_string.sa_suffix.result}"
}

resource "azurerm_storage_account" "backups" {
  name                     = local.sa_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    delete_retention_policy {
      days = var.backup_retention_days
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "backups" {
  name               = "backups"
  storage_account_id = azurerm_storage_account.backups.id
}
