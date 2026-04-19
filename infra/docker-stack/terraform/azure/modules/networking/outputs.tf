output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "subnet_id" {
  description = "ID of the nodes subnet (10.0.1.0/24)."
  value       = azurerm_subnet.nodes.id
}

output "bastion_subnet_id" {
  description = "ID of the AzureBastionSubnet. Null when enable_bastion = false."
  value       = var.enable_bastion ? azurerm_subnet.bastion[0].id : null
}

output "nsg_id" {
  description = "ID of the NSG applied to the nodes subnet."
  value       = azurerm_network_security_group.nodes.id
}
