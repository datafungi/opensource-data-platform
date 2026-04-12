output "resource_group_name" {
  description = "Name of the lab resource group."
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region used by the lab."
  value       = azurerm_resource_group.main.location
}

output "vnet_name" {
  description = "Name of the lab virtual network."
  value       = azurerm_virtual_network.main.name
}

output "vm_private_ips" {
  description = "Private IP address for each VM."
  value = {
    for name, nic in azurerm_network_interface.vms :
    name => nic.private_ip_address
  }
}

output "jumpbox_public_ip" {
  description = "Public IP address for vm-01-control when enabled."
  value       = var.create_jumpbox_public_ip ? azurerm_public_ip.jumpbox[0].ip_address : null
}

output "ssh_to_control_vm" {
  description = "SSH command for the control VM when the jumpbox public IP is enabled."
  value       = var.create_jumpbox_public_ip ? "ssh ${var.admin_username}@${azurerm_public_ip.jumpbox[0].ip_address}" : null
}

output "vm_ids" {
  description = "Azure resource IDs for the lab VMs."
  value = {
    for name, vm in azurerm_linux_virtual_machine.vms :
    name => vm.id
  }
}

output "storage_account_name" {
  description = "Storage account for lab backups and artifacts."
  value       = azurerm_storage_account.lab.name
}

output "key_vault_name" {
  description = "Key Vault for lab secrets."
  value       = azurerm_key_vault.main.name
}

output "automation_account_name" {
  description = "Automation account used for inactivity shutdown."
  value       = var.enable_inactivity_shutdown ? azurerm_automation_account.main[0].name : null
}
