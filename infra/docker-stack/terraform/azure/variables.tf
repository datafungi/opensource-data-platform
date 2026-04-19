variable "location" {
  type        = string
  default     = "southeastasia"
  description = "Azure region for all resources."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment label applied to all resource names and tags."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project" {
  type        = string
  default     = "data-platform"
  description = "Project name used as a prefix for all resource names."
}

variable "vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "Azure VM SKU for all three cluster nodes."
}

variable "admin_username" {
  type        = string
  default     = "azureuser"
  description = "Linux admin username provisioned on every VM."
}

variable "enable_bastion" {
  type        = bool
  default     = false
  description = "Deploy Azure Bastion (Basic SKU) for SSH access. Adds ~$140/month. When false, set allowed_ssh_cidr to restrict direct SSH."
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = ""
  description = "Source CIDR allowed to SSH into VMs via NSG rule. Required when enable_bastion = false. Leave empty when using Bastion."
}

variable "backup_retention_days" {
  type        = number
  default     = 30
  description = "Soft-delete retention period in days for the backup blob container."
}

variable "data_disk_size_gb" {
  type        = number
  default     = 256
  description = "Size in GiB of the Premium SSD data disk attached to each node for the GlusterFS brick."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags merged into the common tag set applied to all resources."
}
