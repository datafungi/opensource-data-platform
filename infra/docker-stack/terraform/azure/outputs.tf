output "resource_group_name" {
  description = "Name of the deployed resource group."
  value       = azurerm_resource_group.this.name
}

output "node_public_ip" {
  description = "Public IP address of node-1 — the Swarm primary and routing mesh entry point."
  value       = module.compute.node_public_ip
}

output "node_private_ips" {
  description = "Private IP addresses of all three cluster nodes."
  value       = module.compute.node_private_ips
}

output "key_vault_uri" {
  description = "URI of the Azure Key Vault used to store Swarm tokens and service credentials."
  value       = module.keyvault.key_vault_uri
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault."
  value       = module.keyvault.key_vault_name
}

output "backup_storage_account_name" {
  description = "Storage account name for nightly pg_dump and Redis backups."
  value       = module.storage.storage_account_name
}

output "backup_container_name" {
  description = "Blob container name for backups."
  value       = module.storage.backup_container_name
}

output "cluster_identity_client_id" {
  description = "Client ID of the user-assigned managed identity attached to all cluster VMs."
  value       = azurerm_user_assigned_identity.cluster.client_id
}

output "ssh_private_key_path" {
  description = "Local path to the generated SSH private key for cluster access."
  value       = local_sensitive_file.cluster_private_key.filename
}

output "cluster_identity_principal_id" {
  description = "Principal (object) ID of the cluster managed identity — useful for adding extra role assignments."
  value       = azurerm_user_assigned_identity.cluster.principal_id
}
