output "key_vault_id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Vault URI used by VMs and the az CLI to retrieve secrets."
  value       = azurerm_key_vault.this.vault_uri
}

output "postgres_secret_names" {
  description = "Key Vault secret names for Postgres credentials — read by Ansible to create Docker secrets."
  value = {
    superuser = azurerm_key_vault_secret.postgres_superuser_password.name
    airflow   = azurerm_key_vault_secret.postgres_airflow_password.name
    polaris   = azurerm_key_vault_secret.postgres_polaris_password.name
  }
}
