output "storage_account_name" {
  description = "Name of the backup storage account."
  value       = azurerm_storage_account.backups.name
}

output "storage_account_id" {
  description = "Resource ID of the backup storage account."
  value       = azurerm_storage_account.backups.id
}

output "backup_container_name" {
  description = "Name of the blob container used for pg_dump and Redis backups."
  value       = azurerm_storage_container.backups.name
}
