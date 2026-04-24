resource "random_string" "kv_suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  # Key Vault names: 3-24 chars, letters, numbers, hyphens; globally unique.
  # Truncate prefix to 16 chars to leave room for "-kv-" + 4 random chars.
  kv_name = "${substr(var.name_prefix, 0, min(length(var.name_prefix), 16))}-kv-${random_string.kv_suffix.result}"
}

resource "azurerm_key_vault" "this" {
  name                       = local.kv_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

# The identity running `terraform apply` needs full secret management access
# to populate Swarm tokens, service credentials, and fernet keys post-apply.
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = var.deployer_object_id

  secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
}

# Cluster VMs read Swarm tokens and credentials via the managed identity.
resource "azurerm_key_vault_access_policy" "cluster_vms" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = var.tenant_id
  object_id    = var.vm_principal_id

  secret_permissions = ["Get", "List"]
}

# ── Postgres database credentials ─────────────────────────────────────────────
# Passwords are generated here so Terraform can assemble the Airflow connection
# string in the same apply — no manual secret population required.

resource "random_password" "postgres_superuser" {
  length  = 32
  special = false
}

resource "random_password" "postgres_airflow" {
  length  = 32
  special = false
}

resource "random_password" "postgres_polaris" {
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "postgres_superuser_password" {
  name         = "postgres-superuser-password"
  value        = random_password.postgres_superuser.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

resource "azurerm_key_vault_secret" "postgres_airflow_password" {
  name         = "postgres-airflow-password"
  value        = random_password.postgres_airflow.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

resource "azurerm_key_vault_secret" "postgres_polaris_password" {
  name         = "postgres-polaris-password"
  value        = random_password.postgres_polaris.result
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}

# Assembled here so Airflow's AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_SECRET lookup
# resolves correctly. The hostname "postgres" is the Docker service name.
resource "azurerm_key_vault_secret" "airflow_sql_alchemy_conn" {
  name         = "airflow-config-sql-alchemy-conn"
  value        = "postgresql+psycopg2://airflow:${random_password.postgres_airflow.result}@postgres/airflow"
  key_vault_id = azurerm_key_vault.this.id
  depends_on   = [azurerm_key_vault_access_policy.deployer]
}
