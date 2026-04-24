variable "resource_group_name" {
  type        = string
  description = "Resource group for all network-layer resources."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names."
}

variable "enable_bastion" {
  type        = bool
  default     = false
  description = "When true, creates AzureBastionSubnet (/27) and deploys an Azure Bastion host."
}

variable "enable_tailscale" {
  type        = bool
  default     = false
  description = "When true, creates tailscale-subnet (10.54.0.0/24) and deploys the Tailscale subnet router / VPN exit node VM."
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = ""
  description = "Source CIDR for the SSH inbound NSG rule on the nodes subnet. Empty string disables the rule (use Bastion or Tailscale instead)."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B1s"
  description = "Azure VM SKU for the Tailscale router. Standard_B1s (1 vCPU, 1 GiB) is sufficient for subnet routing and VPN exit node traffic."
}

variable "admin_username" {
  type        = string
  default     = "azureuser"
  description = "Linux admin username for the Tailscale VM."
}

variable "ssh_public_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "SSH public key for Tailscale VM access. Required when enable_tailscale = true."
}

variable "key_vault_id" {
  type        = string
  default     = null
  description = "Resource ID of the Key Vault used to store the Tailscale auth key. Required when enable_tailscale = true."
}

variable "key_vault_name" {
  type        = string
  default     = ""
  description = "Name of the Key Vault (used in cloud-init to build the Vault URI). Required when enable_tailscale = true."
}

variable "tenant_id" {
  type        = string
  default     = ""
  description = "Azure AD tenant ID for the Tailscale VM Key Vault access policy. Required when enable_tailscale = true."
}

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Tailscale auth key stored in Key Vault and retrieved by cloud-init on first boot. Must be a reusable key or OAuth client secret. Required when enable_tailscale = true."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all network-layer resources."
}
