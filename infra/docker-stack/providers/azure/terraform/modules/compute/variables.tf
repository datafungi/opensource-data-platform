variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy compute resources into."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names."
}

variable "vm_size" {
  type        = string
  default     = "Standard_D2as_v5"
  description = "Azure VM SKU for all three cluster nodes."
}

variable "admin_username" {
  type        = string
  default     = "azureuser"
  description = "Linux admin username."
}

variable "ssh_public_key" {
  type        = string
  sensitive   = true
  description = "SSH public key content for VM access."
}

variable "subnet_id" {
  type        = string
  description = "ID of the nodes subnet where NICs are attached."
}

variable "data_disk_size_gb" {
  type        = number
  default     = 32
  description = "Size in GiB of the GlusterFS brick data disk (Premium SSD) per node."
}

variable "identity_id" {
  type        = string
  description = "Resource ID of the user-assigned managed identity to attach to every VM."
}

variable "key_vault_name" {
  type        = string
  description = "Name of the Key Vault where Swarm join tokens are stored by cloud-init."
}

variable "backup_storage_account_name" {
  type        = string
  description = "Storage account name for pg_dump and Redis backups (injected into cloud-init environment)."
}

variable "backup_container_name" {
  type        = string
  description = "Blob container name for backups."
}

variable "enable_bastion" {
  type        = bool
  default     = false
  description = "When true, deploy Azure Bastion host."
}

variable "bastion_subnet_id" {
  type        = string
  default     = null
  description = "ID of AzureBastionSubnet. Required when enable_bastion = true."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all compute resources."
}

variable "auto_shutdown_enabled" {
  type        = bool
  default     = false
  description = "Enable daily auto-shutdown for cluster nodes."
}

variable "auto_shutdown_time" {
  type        = string
  default     = "2300"
  description = "Daily auto-shutdown time in HHMM format."
}

variable "auto_shutdown_timezone" {
  type        = string
  default     = "SE Asia Standard Time"
  description = "Windows timezone name for auto_shutdown_time."
}
