locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = merge(
    {
      project     = var.project
      environment = var.environment
      managed_by  = "terraform"
      stack       = "docker-swarm"
    },
    var.tags
  )
}

# Generates an ED25519 key pair. Private key is stored in Terraform state
# (sensitive) and written to disk; public key is passed to the VMs.
resource "tls_private_key" "cluster" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "cluster_private_key" {
  content         = tls_private_key.cluster.private_key_openssh
  filename        = "${pathexpand("~/.ssh")}/${local.name_prefix}.pem"
  file_permission = "0600"
}

# ── Resource groups ───────────────────────────────────────────────────────────
# Networking and platform resources live in separate resource groups so they
# can have independent lifecycles and RBAC scopes. Network resources (VNet,
# subnets, NSGs, Tailscale VM) change rarely; platform resources (cluster VMs,
# storage, Key Vault) may be rebuilt independently without touching the network
# layer.

resource "azurerm_resource_group" "network" {
  name     = "${local.name_prefix}-network-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "platform" {
  name     = "${local.name_prefix}-platform-rg"
  location = var.location
  tags     = local.common_tags
}

# User-assigned managed identity shared by all cluster VMs.
# Declared here (not inside keyvault or compute modules) to break the
# circular dependency: keyvault needs the principal_id to grant access,
# compute needs the identity_id to attach it to VMs.
resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${local.name_prefix}-cluster-id"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  tags                = local.common_tags
}

# Generates a reusable, preauthorized Tailscale auth key via the Tailscale API.
# The key is stored in Key Vault and retrieved by the VM's cloud-init at boot —
# no manual key creation or rotation required.
resource "tailscale_tailnet_key" "gateway" {
  count = var.enable_tailscale ? 1 : 0

  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 days
  description   = "${local.name_prefix} gateway"
  tags          = var.tailscale_tags
}

module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.network.name
  location            = var.location
  name_prefix         = local.name_prefix
  enable_bastion      = var.enable_bastion
  enable_tailscale    = var.enable_tailscale
  allowed_ssh_cidr    = var.allowed_ssh_cidr
  admin_username      = var.admin_username
  ssh_public_key      = tls_private_key.cluster.public_key_openssh
  key_vault_id        = module.keyvault.key_vault_id
  key_vault_name      = module.keyvault.key_vault_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  tailscale_auth_key  = coalesce(one(tailscale_tailnet_key.gateway[*].key), "")
  tags                = local.common_tags

  # Key Vault and its deployer access policy must exist before this module
  # tries to write the Tailscale auth key secret.
  depends_on = [module.keyvault]
}

module "storage" {
  source = "./modules/storage"

  resource_group_name           = azurerm_resource_group.platform.name
  location                      = var.location
  name_prefix                   = local.name_prefix
  backup_retention_days         = var.backup_retention_days
  cluster_identity_principal_id = azurerm_user_assigned_identity.cluster.principal_id
  tags                          = local.common_tags
}

module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = azurerm_resource_group.platform.name
  location            = var.location
  name_prefix         = local.name_prefix
  tenant_id           = data.azurerm_client_config.current.tenant_id
  deployer_object_id  = data.azurerm_client_config.current.object_id
  vm_principal_id     = azurerm_user_assigned_identity.cluster.principal_id
  tags                = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  resource_group_name         = azurerm_resource_group.platform.name
  location                    = var.location
  name_prefix                 = local.name_prefix
  vm_size                     = var.vm_size
  admin_username              = var.admin_username
  ssh_public_key              = tls_private_key.cluster.public_key_openssh
  subnet_id                   = module.network.subnet_id
  data_disk_size_gb           = var.data_disk_size_gb
  identity_id                 = azurerm_user_assigned_identity.cluster.id
  key_vault_name              = module.keyvault.key_vault_name
  backup_storage_account_name = module.storage.storage_account_name
  backup_container_name       = module.storage.backup_container_name
  enable_bastion              = var.enable_bastion
  bastion_subnet_id           = module.network.bastion_subnet_id
  auto_shutdown_enabled       = var.auto_shutdown_enabled
  auto_shutdown_time          = var.auto_shutdown_time
  auto_shutdown_timezone      = var.auto_shutdown_timezone
  tags                        = local.common_tags

  # VMs need Key Vault to exist before cloud-init can store Swarm tokens.
  depends_on = [module.keyvault]
}
