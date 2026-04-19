locals {
  node_count  = 3
  private_ips = ["10.0.1.10", "10.0.1.11", "10.0.1.12"]
}

# ── Public IP (node-1 only) ───────────────────────────────────────────────────
# Single entry point for the Docker Swarm routing mesh.
# The NSG limits inbound to ports 8080 (Airflow UI) and 3000 (Grafana).

resource "azurerm_public_ip" "node1" {
  name                = "${var.name_prefix}-node-1-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ── Network interfaces ────────────────────────────────────────────────────────

resource "azurerm_network_interface" "nodes" {
  count               = local.node_count
  name                = "${var.name_prefix}-node-${count.index + 1}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.private_ips[count.index]
    public_ip_address_id          = count.index == 0 ? azurerm_public_ip.node1.id : null
  }
}

# ── Virtual machines ──────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "nodes" {
  count               = local.node_count
  name                = "${var.name_prefix}-node-${count.index + 1}"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.nodes[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.name_prefix}-node-${count.index + 1}-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
    admin_username              = var.admin_username
    is_primary                  = count.index == 0
    private_ip                  = local.private_ips[count.index]
    primary_ip                  = local.private_ips[0]
    key_vault_name              = var.key_vault_name
    backup_storage_account_name = var.backup_storage_account_name
    backup_container_name       = var.backup_container_name
  }))

  tags = var.tags
}

# ── Data disks (GlusterFS bricks) ────────────────────────────────────────────
# One Premium SSD per node. Formatted as XFS and mounted by cloud-init.
# caching = "None" is required for GlusterFS — write-caching must be disabled
# at the OS level to preserve fsync semantics.

resource "azurerm_managed_disk" "nodes" {
  count                = local.node_count
  name                 = "${var.name_prefix}-node-${count.index + 1}-data"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "nodes" {
  count              = local.node_count
  managed_disk_id    = azurerm_managed_disk.nodes[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.nodes[count.index].id
  lun                = 0
  caching            = "None"
}

# ── Azure Bastion (optional) ──────────────────────────────────────────────────

resource "azurerm_public_ip" "bastion" {
  count               = var.enable_bastion ? 1 : 0
  name                = "${var.name_prefix}-bastion-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  count               = var.enable_bastion ? 1 : 0
  name                = "${var.name_prefix}-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig1"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
