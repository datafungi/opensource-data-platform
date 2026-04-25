# ── Virtual network ───────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  address_space       = ["10.54.0.0/16"]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "azurerm_subnet" "nodes" {
  name                 = "nodes-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.54.1.0/24"]
}

# Azure Bastion requires a dedicated subnet named exactly "AzureBastionSubnet" with a /27 or larger prefix.
resource "azurerm_subnet" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.54.2.0/27"]
}

resource "azurerm_subnet" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                 = "tailscale-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.54.0.0/24"]
}

# ── NSG: cluster nodes ────────────────────────────────────────────────────────

resource "azurerm_network_security_group" "nodes" {
  name                = "${var.name_prefix}-nodes-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "allow_airflow_ui" {
  name                        = "Allow-Airflow-UI"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = var.enable_tailscale ? "10.54.0.0/24" : "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "allow_grafana" {
  name                        = "Allow-Grafana"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3000"
  source_address_prefix       = var.enable_tailscale ? "10.54.0.0/24" : "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "allow_portainer" {
  name                        = "Allow-Portainer"
  priority                    = 115
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "9443"
  source_address_prefix       = var.enable_tailscale ? "10.54.0.0/24" : "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "allow_prometheus" {
  name                        = "Allow-Prometheus"
  priority                    = 117
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "9090"
  source_address_prefix       = var.enable_tailscale ? "10.54.0.0/24" : "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

# Conditional SSH rule — only created when a specific source CIDR is provided.
# Leave allowed_ssh_cidr empty when using Azure Bastion or Tailscale.
resource "azurerm_network_security_rule" "allow_ssh" {
  count = var.allowed_ssh_cidr != "" ? 1 : 0

  name                        = "Allow-SSH"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.allowed_ssh_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

# Allows SSH from the Tailscale subnet router to cluster nodes. Tailscale
# masquerades forwarded traffic behind the subnet router's own IP (10.54.0.4),
# so this is the source the nodes NSG sees for Tailscale-routed SSH sessions.
resource "azurerm_network_security_rule" "allow_ssh_tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                        = "Allow-SSH-Tailscale"
  priority                    = 125
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "10.54.0.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "swarm_manager" {
  name                        = "Allow-Swarm-Manager-TCP"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "2377"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "swarm_discovery_tcp" {
  name                        = "Allow-Swarm-Discovery-TCP"
  priority                    = 210
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "7946"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "swarm_discovery_udp" {
  name                        = "Allow-Swarm-Discovery-UDP"
  priority                    = 220
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "7946"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "swarm_overlay" {
  name                        = "Allow-Swarm-Overlay-VXLAN"
  priority                    = 230
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "4789"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "allow_node_exporter" {
  name                        = "Allow-NodeExporter"
  priority                    = 260
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "9100"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "gluster_management" {
  name                        = "Allow-GlusterFS-Management"
  priority                    = 240
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "24007-24008"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "gluster_bricks" {
  name                        = "Allow-GlusterFS-Bricks"
  priority                    = 250
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "49152-65535"
  source_address_prefix       = "10.54.1.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "Deny-All-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.nodes.name
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

# ── NSG: Tailscale subnet ─────────────────────────────────────────────────────

resource "azurerm_network_security_group" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                = "${var.name_prefix}-tailscale-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# UDP 41641: Tailscale's WireGuard port. Opening this inbound allows direct
# peer-to-peer connections from tailnet devices, avoiding DERP relay hops
# and giving lower latency for subnet routing and VPN traffic.
resource "azurerm_network_security_rule" "tailscale_wireguard" {
  count = var.enable_tailscale ? 1 : 0

  name                        = "Allow-Tailscale-WireGuard"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "41641"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.tailscale[0].name
}

# SSH restricted to VNet-internal traffic only.
# Once Tailscale is up, access the VM via the tailnet — no public SSH needed.
resource "azurerm_network_security_rule" "tailscale_ssh" {
  count = var.enable_tailscale ? 1 : 0

  name                        = "Allow-SSH-VNet"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.tailscale[0].name
}

resource "azurerm_network_security_rule" "tailscale_deny_inbound" {
  count = var.enable_tailscale ? 1 : 0

  name                        = "Deny-All-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.tailscale[0].name
}

resource "azurerm_subnet_network_security_group_association" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  subnet_id                 = azurerm_subnet.tailscale[0].id
  network_security_group_id = azurerm_network_security_group.tailscale[0].id
}

# ── Tailscale gateway VM ──────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                = "${var.name_prefix}-tailscale-id"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Allow the Tailscale VM's managed identity to read its auth key from Key Vault.
resource "azurerm_key_vault_access_policy" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  key_vault_id = var.key_vault_id
  tenant_id    = var.tenant_id
  object_id    = azurerm_user_assigned_identity.tailscale[0].principal_id

  secret_permissions = ["Get", "List"]
}

# Store the Tailscale auth key in Key Vault so cloud-init can retrieve it at
# boot using the VM's managed identity — no secrets in cloud-init or user-data.
resource "azurerm_key_vault_secret" "tailscale_auth_key" {
  count = var.enable_tailscale ? 1 : 0

  name         = "tailscale-auth-key"
  value        = var.tailscale_auth_key
  key_vault_id = var.key_vault_id
}

resource "azurerm_public_ip" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                = "${var.name_prefix}-tailscale-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                = "${var.name_prefix}-tailscale-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  # Azure NIC-level IP forwarding: required so the NIC passes traffic destined
  # for addresses other than its own (subnet router traffic from Tailscale peers).
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.tailscale[0].id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.54.0.4"
    public_ip_address_id          = azurerm_public_ip.tailscale[0].id
  }
}

resource "azurerm_linux_virtual_machine" "tailscale" {
  count = var.enable_tailscale ? 1 : 0

  name                = "${var.name_prefix}-tailscale"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.tailscale[0].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.name_prefix}-tailscale-os"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.tailscale[0].id]
  }

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
    key_vault_name = var.key_vault_name
    hostname       = "${var.name_prefix}-tailscale"
  }))

  tags = var.tags

  depends_on = [
    azurerm_key_vault_access_policy.tailscale,
    azurerm_key_vault_secret.tailscale_auth_key,
  ]
}
