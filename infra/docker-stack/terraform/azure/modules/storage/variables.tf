variable "resource_group_name" {
  type        = string
  description = "Resource group to deploy the storage account into."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name_prefix" {
  type        = string
  description = "Prefix used to derive the storage account name (hyphens stripped; truncated to satisfy 24-char limit)."
}

variable "backup_retention_days" {
  type        = number
  default     = 30
  description = "Blob soft-delete retention period in days."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the storage account."
}

variable "cluster_identity_principal_id" {
  type        = string
  description = "Principal ID of the cluster managed identity — granted Storage Blob Data Contributor on this account."
}
