output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "subnet_id" {
  description = "ID of the nodes subnet (10.54.1.0/24)."
  value       = azurerm_subnet.nodes.id
}

output "bastion_subnet_id" {
  description = "ID of AzureBastionSubnet. Null when enable_bastion = false."
  value       = var.enable_bastion ? azurerm_subnet.bastion[0].id : null
}

output "nsg_id" {
  description = "ID of the NSG applied to the nodes subnet."
  value       = azurerm_network_security_group.nodes.id
}

output "tailscale_public_ip" {
  description = "Public IP address of the Tailscale subnet router / VPN exit node. Null when enable_tailscale = false."
  value       = var.enable_tailscale ? azurerm_public_ip.tailscale[0].ip_address : null
}

output "tailscale_private_ip" {
  description = "Static private IP of the Tailscale VM within tailscale-subnet (10.54.0.0/24). Null when enable_tailscale = false."
  value       = var.enable_tailscale ? azurerm_network_interface.tailscale[0].private_ip_address : null
}

output "tailscale_vm_id" {
  description = "Resource ID of the Tailscale VM. Null when enable_tailscale = false."
  value       = var.enable_tailscale ? azurerm_linux_virtual_machine.tailscale[0].id : null
}

output "tailscale_identity_principal_id" {
  description = "Principal ID of the Tailscale VM managed identity. Null when enable_tailscale = false."
  value       = var.enable_tailscale ? azurerm_user_assigned_identity.tailscale[0].principal_id : null
}
