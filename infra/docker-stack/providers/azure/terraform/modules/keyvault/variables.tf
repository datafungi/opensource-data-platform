variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy the Key Vault into."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name_prefix" {
  type        = string
  description = "Prefix used to derive the Key Vault name (truncated; KV names are max 24 chars)."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant ID for Key Vault access policies."
}

variable "deployer_object_id" {
  type        = string
  description = "Object ID of the identity running terraform apply — granted full secret management access."
}

variable "vm_principal_id" {
  type        = string
  description = "Principal ID of the cluster VM managed identity — granted Get and List secret access."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the Key Vault."
}
