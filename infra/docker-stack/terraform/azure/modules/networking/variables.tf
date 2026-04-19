variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy networking resources into."
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
  description = "When true, creates AzureBastionSubnet (/27) and a Bastion host resource."
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = ""
  description = "Source CIDR for the SSH inbound NSG rule. Empty string disables the rule (use when enable_bastion = true)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all networking resources."
}
