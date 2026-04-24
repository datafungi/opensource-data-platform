# Apache Airflow — Secrets Management
### Azure Key Vault Backend on Docker Swarm

|                    |                                     |
|--------------------|-------------------------------------|
| **Scope**          | Apache Airflow on Docker Swarm Mode |
| **Applies to**     | Airflow 3.x                         |
| **Classification** | Internal / Operational              |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Managed Identity Authentication](#3-managed-identity-authentication)
4. [Key Vault Backend Configuration](#4-key-vault-backend-configuration)
5. [Infrastructure Secrets (`_SECRET`)](#5-infrastructure-secrets-_secret)
6. [DAG Connections and Variables](#6-dag-connections-and-variables)
7. [Key Vault Secret Naming Reference](#7-key-vault-secret-naming-reference)
8. [Key Rotation](#8-key-rotation)
9. [Secret Scope Per Service](#9-secret-scope-per-service)
10. [Ansible Deployment Notes](#10-ansible-deployment-notes)
11. [Caveats and Best Practices](#11-caveats-and-best-practices)

---

## 1. Overview

Airflow secrets are stored in **Azure Key Vault** and retrieved at runtime using the cluster VMs'
**user-assigned managed identity** — no credentials are stored in the stack file or on disk.

Two mechanisms work together:

| Mechanism                | Purpose                                                 | How It Works                                                                                     |
|--------------------------|---------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `_SECRET` env var suffix | Infrastructure secrets: Fernet key, DB conn, broker URL | Airflow reads the secret name from the env var, then fetches the value from Key Vault at startup |
| `AzureKeyVaultBackend`   | DAG connections and variables                           | Airflow backend that resolves connections/variables from Key Vault on demand                     |

The only Docker secret used is `azure_mi_client_id` — the managed identity client ID needed to
authenticate to Key Vault when multiple user-assigned identities are attached to the VM.

---

## 2. Prerequisites

- **Provider installed:** `apache-airflow-providers-microsoft-azure` must be present in the
  Airflow image. It is already included in `requirements.txt`.
- **Key Vault access:** The cluster managed identity already has `Get` and `List` secret
  permissions on the Key Vault, granted by Terraform via `azurerm_key_vault_access_policy.cluster_vms`.
- **Managed identity client ID:** Available from the Terraform output or Azure CLI. Used to
  disambiguate which user-assigned identity to use when authenticating.

---

## 3. Managed Identity Authentication

The `AzureKeyVaultBackend` uses `DefaultAzureCredential`, which automatically picks up the VM's
managed identity. Because the identity is **user-assigned** (not system-assigned), the client ID
must be specified to avoid ambiguity.

### Store the client ID as a Docker secret

```bash
# Retrieve client ID from Azure (or Terraform output)
CLIENT_ID=$(az identity show \
  --name <name_prefix>-cluster-id \
  --resource-group <name_prefix>-platform-rg \
  --query clientId -o tsv)

echo "$CLIENT_ID" | docker secret create azure_mi_client_id -
```

### Inject at container startup via entrypoint wrapper

Create `scripts/airflow-entrypoint.sh` and deploy it alongside the stack:

```bash
#!/usr/bin/env bash
set -euo pipefail
export AZURE_CLIENT_ID="$(cat /run/secrets/azure_mi_client_id)"
exec /entrypoint "$@"
```

`DefaultAzureCredential` and `ManagedIdentityCredential` both respect `AZURE_CLIENT_ID`
automatically — no additional configuration is needed in `backend_kwargs`.

Reference the wrapper in the stack's anchor block:

```yaml
x-airflow-common: &airflow-common
  entrypoint: ["/opt/scripts/airflow-entrypoint.sh"]
  secrets:
    - azure_mi_client_id
  volumes:
    - ./scripts/airflow-entrypoint.sh:/opt/scripts/airflow-entrypoint.sh:ro

secrets:
  azure_mi_client_id:
    external: true
```

---

## 4. Key Vault Backend Configuration

Set these on all Airflow services (include in the `x-airflow-common` anchor):

```yaml
environment:
  AIRFLOW__SECRETS__BACKEND: airflow.providers.microsoft.azure.secrets.key_vault.AzureKeyVaultBackend
  AIRFLOW__SECRETS__BACKEND_KWARGS: >-
    {
      "vault_url": "https://<keyvault-name>.vault.azure.net/",
      "connections_prefix": "airflow-connections",
      "variables_prefix": "airflow-variables",
      "config_prefix": "airflow-config"
    }
```

The `vault_url` is not sensitive — it can be templated directly by Ansible from the Terraform
output or Key Vault name variable.

---

## 5. Infrastructure Secrets (`_SECRET`)

The `_SECRET` suffix tells Airflow to fetch the config value from the secrets backend using the
given name. It is supported for the same allowlist as `_CMD`:

| Environment Variable                         | Value (Key Vault lookup key) |
|----------------------------------------------|------------------------------|
| `AIRFLOW__CORE__FERNET_KEY_SECRET`           | `fernet-key`                 |
| `AIRFLOW__API__SECRET_KEY_SECRET`            | `api-secret-key`             |
| `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_SECRET` | `sql-alchemy-conn`           |
| `AIRFLOW__CELERY__BROKER_URL_SECRET`         | `broker-url`                 |
| `AIRFLOW__CELERY__RESULT_BACKEND_SECRET`     | `result-backend`             |
| `AIRFLOW__SMTP__SMTP_PASSWORD_SECRET`        | `smtp-password`              |

The value of each env var is passed to `backend.get_config(key)`, which fetches the Key Vault
secret named `{config_prefix}--{key}` (see [Section 7](#7-key-vault-secret-naming-reference)).

These values are resolved **once at container startup** — a service restart is required after
rotating any of these secrets in Key Vault.

Add to the `x-airflow-common` anchor:

```yaml
environment:
  AIRFLOW__CORE__FERNET_KEY_SECRET: "fernet-key"
  AIRFLOW__API__SECRET_KEY_SECRET: "api-secret-key"
  AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_SECRET: "sql-alchemy-conn"
  AIRFLOW__CELERY__BROKER_URL_SECRET: "broker-url"
  AIRFLOW__CELERY__RESULT_BACKEND_SECRET: "result-backend"
```

---

## 6. DAG Connections and Variables

Once the backend is configured, DAGs retrieve connections and variables from Key Vault
transparently — no code changes are needed:

```python
from airflow.hooks.base import BaseHook
from airflow.models import Variable

conn = BaseHook.get_connection("my_postgres")   # fetches from Key Vault
output_path = Variable.get("output_path")        # fetches from Key Vault
```

**Lookup precedence** (fixed, not configurable):

1. `AzureKeyVaultBackend` — fetches from Key Vault
2. Environment variables — `AIRFLOW_CONN_*`, `AIRFLOW_VAR_*`
3. Metastore database

**Note:** `Variable.set()` and `Connection.set()` always write to the metastore, not Key Vault.
Connections and variables that should come from Key Vault must be created there directly.

---

## 7. Key Vault Secret Naming Reference

The backend constructs the full Key Vault secret name as `{prefix}--{key}`, where `key` has
underscores replaced with hyphens and is lowercased.

| Type       | Prefix                | Example key        | Full Key Vault secret name         |
|------------|-----------------------|--------------------|------------------------------------|
| Config     | `airflow-config`      | `fernet-key`       | `airflow-config--fernet-key`       |
| Config     | `airflow-config`      | `sql-alchemy-conn` | `airflow-config--sql-alchemy-conn` |
| Connection | `airflow-connections` | `my_postgres`      | `airflow-connections--my-postgres` |
| Variable   | `airflow-variables`   | `output_path`      | `airflow-variables--output-path`   |

**Creating secrets in Key Vault:**

```bash
KV="<keyvault-name>"

# Infrastructure secrets
az keyvault secret set --vault-name "$KV" --name "airflow-config--fernet-key"     --value "<fernet-key>"
az keyvault secret set --vault-name "$KV" --name "airflow-config--api-secret-key" --value "<secret>"
az keyvault secret set --vault-name "$KV" --name "airflow-config--sql-alchemy-conn" \
  --value "postgresql+psycopg2://airflow:<password>@postgres/airflow"
az keyvault secret set --vault-name "$KV" --name "airflow-config--broker-url"     --value "redis://redis:6379/0"
az keyvault secret set --vault-name "$KV" --name "airflow-config--result-backend" --value "redis://redis:6379/0"

# DAG connections (value must be a valid Airflow Connection URI)
az keyvault secret set --vault-name "$KV" --name "airflow-connections--my-postgres" \
  --value "postgresql://user:password@host:5432/mydb"

# DAG variables
az keyvault secret set --vault-name "$KV" --name "airflow-variables--output-path" \
  --value "abfs://container@account.dfs.core.windows.net/output"
```

---

## 8. Key Rotation

Rotating a secret in Key Vault does not require creating a new Docker secret or updating the stack
file — update the value in Key Vault, then restart the affected services.

### Fernet Key Rotation

The Fernet key encrypts connections and variables in the metadata database. A transition period is
required to avoid making existing encrypted values unreadable.

```bash
KV="<keyvault-name>"

# 1. Generate a new Fernet key
NEW_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")

# 2. Read the current key
OLD_KEY=$(az keyvault secret show --vault-name "$KV" --name "airflow-config--fernet-key" --query value -o tsv)

# 3. Set transition value: new,old — Airflow decrypts with either
az keyvault secret set --vault-name "$KV" --name "airflow-config--fernet-key" --value "${NEW_KEY},${OLD_KEY}"

# 4. Restart all Airflow services to pick up the transition key
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker

# 5. Re-encrypt all metadata DB values with the new key
docker exec $(docker ps -q -f name=data-platform_airflow-worker | head -1) \
  airflow rotate-fernet-key

# 6. Set the clean new key only
az keyvault secret set --vault-name "$KV" --name "airflow-config--fernet-key" --value "$NEW_KEY"

# 7. Restart services again to drop the old key from memory
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker
```

### Other Infrastructure Secrets (API key, DB password, broker URL)

```bash
# Update the value in Key Vault
az keyvault secret set --vault-name "$KV" --name "airflow-config--api-secret-key" --value "$(openssl rand -hex 32)"

# Restart the affected services (all sessions are invalidated for the API key)
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
```

### DAG Connections and Variables

Connections and variables are fetched from Key Vault on demand — **no service restart required**
after updating them.

```bash
az keyvault secret set --vault-name "$KV" \
  --name "airflow-connections--my-postgres" \
  --value "postgresql://user:new_password@host:5432/mydb"
```

The next DAG task that accesses `my_postgres` will pick up the new value automatically.

---

## 9. Secret Scope Per Service

The `azure_mi_client_id` Docker secret must be mounted on every service that authenticates to
Key Vault — which is all Airflow services.

| Secret               | API server | Scheduler | DAG processor | Worker | Triggerer |
|----------------------|------------|-----------|---------------|--------|-----------|
| `azure_mi_client_id` | ✅          | ✅         | ✅             | ✅      | ✅         |

Infrastructure secrets (Fernet key, DB conn, etc.) and DAG connections/variables are fetched
directly from Key Vault — no per-service Docker secret declarations are needed for them.

---

## 10. Ansible Deployment Notes

The following Ansible tasks cover the deployment prerequisites.

**Retrieve managed identity client ID and create Docker secret:**

```yaml
- name: Get managed identity client ID
  command: >
    az identity show
    --name {{ name_prefix }}-cluster-id
    --resource-group {{ name_prefix }}-platform-rg
    --query clientId -o tsv
  register: mi_client_id
  delegate_to: localhost

- name: Create azure_mi_client_id Docker secret
  community.docker.docker_secret:
    name: azure_mi_client_id
    data: "{{ mi_client_id.stdout }}"
    state: present
```

**Populate Key Vault secrets (run once per environment):**

```yaml
- name: Set Airflow infrastructure secrets in Key Vault
  command: >
    az keyvault secret set
    --vault-name {{ keyvault_name }}
    --name {{ item.name }}
    --value {{ item.value }}
  loop:
    - { name: "airflow-config--fernet-key",     value: "{{ airflow_fernet_key }}" }
    - { name: "airflow-config--api-secret-key",  value: "{{ airflow_api_secret }}" }
    - { name: "airflow-config--sql-alchemy-conn", value: "{{ airflow_db_conn }}" }
    - { name: "airflow-config--broker-url",       value: "{{ airflow_broker_url }}" }
    - { name: "airflow-config--result-backend",   value: "{{ airflow_result_backend }}" }
  delegate_to: localhost
  no_log: true
```

The Key Vault name and infrastructure secret values should come from Ansible Vault or be
retrieved from Terraform outputs.

---

## 11. Caveats and Best Practices

- **Infrastructure secrets are startup-only.** `_SECRET` values are resolved when the container
  starts. Rotating them in Key Vault requires a service restart to take effect.
- **DAG connections and variables are fetched on demand.** Updates to Key Vault are picked up
  immediately by the next task access — no restart needed.
- **`Variable.set()` writes to the metastore, not Key Vault.** Never use the Airflow UI or CLI to
  set a variable that should come from Key Vault — it will shadow the Key Vault value at the
  wrong precedence level.
- **Fernet key rotation requires the transition period.** Set `new,old` first, re-encrypt, then
  set `new` only. Skipping the transition will make existing encrypted DB values unreadable.
- **Long-lived workers may cache connections.** After rotating a connection in Key Vault, tasks
  that hold a live database connection may not see the new credentials until the next connection
  cycle. Force a worker restart if immediate propagation is needed:
  `docker service update --force data-platform_airflow-worker`.
- **Key Vault request throttling.** Key Vault is rate-limited. For high-frequency variable lookups
  in DAGs, prefer using the metastore (`Variable.set()`) for non-sensitive values and reserve Key
  Vault for credentials.
