terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.68.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

data "azurerm_client_config" "current" {}

locals {
  project_slug = lower(replace(var.project_name, "-", ""))
  common_tags = merge(
    {
      managed_by = "terraform"
      project    = var.project_name
    },
    var.tags
  )

  vms = {
    vm-01-control = {
      private_ip = "10.10.1.10"
      role       = "control"
    }
    vm-02-worker-a = {
      private_ip = "10.10.1.11"
      role       = "worker"
    }
    vm-03-worker-b = {
      private_ip = "10.10.1.12"
      role       = "worker"
    }
  }
}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  numeric = true
  special = false
  upper   = false
}

resource "time_offset" "inactivity_schedule_start" {
  offset_minutes = 15
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project_name}"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "vms" {
  name                            = "snet-vms"
  resource_group_name             = azurerm_resource_group.main.name
  virtual_network_name            = azurerm_virtual_network.main.name
  address_prefixes                = [var.vm_subnet_address_prefix]
  default_outbound_access_enabled = !var.enable_nat_gateway
}

resource "azurerm_public_ip" "nat_gateway" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "pip-${var.project_name}-natgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway" "vms" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "natgw-${var.project_name}-vms"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "vms" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.vms[0].id
  public_ip_address_id = azurerm_public_ip.nat_gateway[0].id
}

resource "azurerm_subnet_nat_gateway_association" "vms" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.vms.id
  nat_gateway_id = azurerm_nat_gateway.vms[0].id
}

resource "azurerm_network_security_group" "vms" {
  name                = "nsg-${var.project_name}-vms"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "ssh" {
  count = length(var.allowed_ssh_cidrs) > 0 ? 1 : 0

  name                        = "allow-ssh-from-approved-cidrs"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.allowed_ssh_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vms.name
}

resource "azurerm_network_security_rule" "internal" {
  name                        = "allow-vnet-internal"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vms.name
}

resource "azurerm_subnet_network_security_group_association" "vms" {
  subnet_id                 = azurerm_subnet.vms.id
  network_security_group_id = azurerm_network_security_group.vms.id
}

resource "azurerm_public_ip" "jumpbox" {
  count = var.create_jumpbox_public_ip ? 1 : 0

  name                = "pip-${var.project_name}-jumpbox"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "vms" {
  for_each = local.vms

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = each.key == "vm-01-control" && var.create_jumpbox_public_ip ? azurerm_public_ip.jumpbox[0].id : null
  }
}

resource "azurerm_availability_set" "vms" {
  name                         = "avset-${var.project_name}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
  tags                         = local.common_tags
}

resource "azurerm_linux_virtual_machine" "vms" {
  for_each = local.vms

  name                            = each.key
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  availability_set_id             = azurerm_availability_set.vms.id
  network_interface_ids           = [azurerm_network_interface.vms[each.key].id]
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_username = var.admin_username
    hostname       = each.key
    install_dokploy = (
      var.install_dokploy_on_control_vm &&
      each.key == "vm-01-control"
    )
  }))
  tags = merge(local.common_tags, { role = each.value.role })

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_managed_disk" "data" {
  for_each = local.vms

  name                 = "datadisk-${each.key}-01"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = var.data_disk_storage_account_type
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = merge(local.common_tags, { role = each.value.role })
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = local.vms

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.vms[each.key].id
  lun                = 0
  caching            = "ReadWrite"
}

resource "azurerm_storage_account" "lab" {
  name                            = substr("st${local.project_slug}${random_string.suffix.result}", 0, 24)
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.common_tags
}

resource "azurerm_storage_container" "backups" {
  name                  = "backups"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "artifacts" {
  name                  = "artifacts"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

resource "azurerm_key_vault" "main" {
  name                       = substr("kv-${var.project_name}-${random_string.suffix.result}", 0, 24)
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

resource "azurerm_role_assignment" "current_user_key_vault_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_log_analytics_workspace" "main" {
  count = var.create_log_analytics_workspace ? 1 : 0

  name                = "log-${var.project_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.common_tags
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "daily" {
  for_each = azurerm_linux_virtual_machine.vms

  virtual_machine_id    = each.value.id
  location              = azurerm_resource_group.main.location
  enabled               = var.enable_daily_shutdown
  daily_recurrence_time = var.daily_shutdown_time
  timezone              = var.daily_shutdown_timezone

  notification_settings {
    enabled = false
  }
}

resource "azurerm_automation_account" "main" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  name                = "aa-${var.project_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "automation_vm_contributor" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  scope                = azurerm_resource_group.main.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.main[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_monitoring_reader" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  scope                = azurerm_resource_group.main.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_automation_account.main[0].identity[0].principal_id
}

resource "azurerm_automation_runbook" "deallocate_inactive_vms" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  name                    = "deallocate-inactive-vms"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main[0].name
  log_progress            = true
  log_verbose             = true
  runbook_type            = "PowerShell"
  description             = "Deallocates lab VMs when average CPU stays below the threshold."

  content = <<-POWERSHELL
    param(
      [string] $resourcegroup,
      [string] $vmnames,
      [int] $cputhreshold
    )

    $ErrorActionPreference = "Stop"
    Disable-AzContextAutosave -Scope Process
    $context = (Connect-AzAccount -Identity).Context
    Set-AzContext -SubscriptionId $context.Subscription.Id | Out-Null

    $names = $vmnames.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $end = Get-Date
    $start = $end.AddHours(-2)
    $allInactive = $true

    foreach ($name in $names) {
      $vm = Get-AzVM -ResourceGroupName $resourcegroup -Name $name -Status
      $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code

      if ($powerState -ne "PowerState/running") {
        Write-Output "$name is $powerState; skipping metric check."
        continue
      }

      $metric = Get-AzMetric `
        -ResourceId $vm.Id `
        -MetricName "Percentage CPU" `
        -StartTime $start `
        -EndTime $end `
        -TimeGrain 00:05:00 `
        -Aggregation Average

      $points = $metric.Data | Where-Object { $null -ne $_.Average }

      if (-not $points) {
        Write-Output "$name has no CPU data; keeping lab running."
        $allInactive = $false
        break
      }

      $avgCpu = ($points | Measure-Object -Property Average -Average).Average
      Write-Output "$name average CPU over last 2 hours: $avgCpu"

      if ($avgCpu -ge $cputhreshold) {
        $allInactive = $false
      }
    }

    if ($allInactive) {
      foreach ($name in $names) {
        Write-Output "Deallocating $name"
        Stop-AzVM -ResourceGroupName $resourcegroup -Name $name -Force
      }
    } else {
      Write-Output "Lab is still active; no VMs deallocated."
    }
  POWERSHELL
}

resource "azurerm_automation_schedule" "inactivity_check" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  name                    = "check-vm-inactivity"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main[0].name
  frequency               = "Hour"
  interval                = 1
  timezone                = "Etc/UTC"
  start_time              = time_offset.inactivity_schedule_start.rfc3339
  description             = "Checks lab VM inactivity every hour."
}

resource "azurerm_automation_job_schedule" "inactivity_check" {
  count = var.enable_inactivity_shutdown ? 1 : 0

  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main[0].name
  schedule_name           = azurerm_automation_schedule.inactivity_check[0].name
  runbook_name            = azurerm_automation_runbook.deallocate_inactive_vms[0].name

  parameters = {
    resourcegroup = azurerm_resource_group.main.name
    vmnames       = join(",", keys(local.vms))
    cputhreshold  = tostring(var.inactivity_cpu_threshold)
  }

  depends_on = [
    azurerm_role_assignment.automation_vm_contributor,
    azurerm_role_assignment.automation_monitoring_reader
  ]
}

resource "azurerm_consumption_budget_subscription" "monthly" {
  count = var.enable_budget_alert && length(var.budget_alert_emails) > 0 ? 1 : 0

  name            = "budget-${var.project_name}"
  subscription_id = data.azurerm_client_config.current.subscription_id
  amount          = var.monthly_budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_start_date
    end_date   = var.budget_end_date
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 95
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }
}
