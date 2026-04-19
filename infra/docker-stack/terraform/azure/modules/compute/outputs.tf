output "node_public_ip" {
  description = "Public IP address assigned to node-1."
  value       = azurerm_public_ip.node1.ip_address
}

output "node_private_ips" {
  description = "Static private IP addresses for all three cluster nodes."
  value       = local.private_ips
}

output "vm_ids" {
  description = "Resource IDs of all three virtual machines."
  value       = azurerm_linux_virtual_machine.nodes[*].id
}

output "vm_names" {
  description = "Names of all three virtual machines."
  value       = azurerm_linux_virtual_machine.nodes[*].name
}

output "data_disk_ids" {
  description = "Resource IDs of the GlusterFS brick data disks."
  value       = azurerm_managed_disk.nodes[*].id
}
