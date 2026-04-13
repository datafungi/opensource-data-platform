variable "project_name" {
  description = "Short name used in Azure resource names."
  type        = string
  default     = "datafungi-lab"
}

variable "location" {
  description = "Azure region for the lab."
  type        = string
  default     = "southeastasia"
}

variable "admin_username" {
  description = "Admin username for the Linux VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used for VM access."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR ranges allowed to SSH into the jump host. Use your public IP with /32."
  type        = list(string)
  default     = []
}

variable "create_jumpbox_public_ip" {
  description = "Whether to attach a public IP to vm-01-control for SSH access."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "Create an explicit NAT Gateway for VM outbound internet access and disable implicit default outbound access."
  type        = bool
  default     = true
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.10.0.0/16"
}

variable "vm_subnet_address_prefix" {
  description = "Address prefix for the VM subnet."
  type        = string
  default     = "10.10.1.0/24"
}

variable "vm_size" {
  description = "Azure VM size for all lab VMs."
  type        = string
  default     = "Standard_D4as_v5"
}

variable "os_disk_size_gb" {
  description = "OS disk size for each VM."
  type        = number
  default     = 32
}

variable "os_disk_storage_account_type" {
  description = "Storage SKU for OS disks."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "data_disk_size_gb" {
  description = "Data disk size for each VM."
  type        = number
  default     = 64
}

variable "data_disk_storage_account_type" {
  description = "Storage SKU for data disks."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "install_dokploy_on_control_vm" {
  description = "Install Dokploy on vm-01-control during cloud-init provisioning."
  type        = bool
  default     = true
}

variable "enable_daily_shutdown" {
  description = "Enable daily Azure DevTest VM shutdown schedules."
  type        = bool
  default     = true
}

variable "daily_shutdown_time" {
  description = "Daily shutdown time in HHMM format."
  type        = string
  default     = "2300"
}

variable "daily_shutdown_timezone" {
  description = "Windows timezone name used by the VM shutdown schedule."
  type        = string
  default     = "SE Asia Standard Time"
}

variable "enable_inactivity_shutdown" {
  description = "Enable an Azure Automation runbook that deallocates VMs after low CPU activity."
  type        = bool
  default     = true
}

variable "inactivity_cpu_threshold" {
  description = "Average CPU threshold below which VMs are treated as inactive."
  type        = number
  default     = 5
}

variable "create_log_analytics_workspace" {
  description = "Create a small Log Analytics workspace for Azure-native logs."
  type        = bool
  default     = true
}

variable "log_analytics_retention_days" {
  description = "Retention period for the Log Analytics workspace."
  type        = number
  default     = 30
}

variable "enable_budget_alert" {
  description = "Create a subscription budget alert when budget_alert_emails is not empty."
  type        = bool
  default     = false
}

variable "monthly_budget_amount" {
  description = "Monthly budget amount in the subscription currency."
  type        = number
  default     = 150
}

variable "budget_alert_emails" {
  description = "Email addresses that receive budget notifications."
  type        = list(string)
  default     = []
}

variable "budget_start_date" {
  description = "Budget start date in RFC3339 format. Use the first day of a month."
  type        = string
  default     = "2026-04-01T00:00:00Z"
}

variable "budget_end_date" {
  description = "Budget end date in RFC3339 format."
  type        = string
  default     = "2036-04-01T00:00:00Z"
}

variable "tags" {
  description = "Additional tags applied to supported resources."
  type        = map(string)
  default     = {}
}
