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

variable "enable_tailscale" {
  type        = bool
  default     = false
  description = "Deploy a dedicated Tailscale VM as a subnet router (access all VNet resources without Tailscale on each VM) and VPN exit node (self-hosted VPN). Requires tailscale_oauth_client_id and tailscale_oauth_client_secret."
}

variable "tailscale_oauth_client_id" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Tailscale OAuth client ID used to generate a reusable auth key via the Tailscale provider. Create at https://login.tailscale.com/admin/settings/oauth. Required when enable_tailscale = true."
}

variable "tailscale_oauth_client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Tailscale OAuth client secret paired with tailscale_oauth_client_id. Required when enable_tailscale = true."
}

variable "tailscale_tags" {
  type        = list(string)
  default     = ["tag:server"]
  description = "ACL tags applied to the Tailscale gateway VM. Tags must be defined in your tailnet ACL policy (tagOwners) before apply. OAuth-generated keys require at least one tag."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags merged into the common tag set applied to all resources."
}

variable "auto_shutdown_enabled" {
  type        = bool
  default     = false
  description = "Enable daily auto-shutdown for cluster nodes. The Tailscale VM is never affected."
}

variable "auto_shutdown_time" {
  type        = string
  default     = "2300"
  description = "Daily auto-shutdown time in HHMM format (e.g. \"2300\" = 11 PM). Interpreted in auto_shutdown_timezone."
}

variable "auto_shutdown_timezone" {
  type        = string
  default     = "SE Asia Standard Time"
  description = "Windows timezone name for auto_shutdown_time. Azure requires Windows timezone IDs (e.g. \"SE Asia Standard Time\" for Asia/Ho_Chi_Minh, \"UTC\" for UTC)."
}
