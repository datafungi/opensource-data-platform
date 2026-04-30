# Airflow Secrets Management

Airflow resolves connections, variables, and configuration values at runtime from
**HashiCorp Vault** (KV v2 secrets engine). No credentials are stored in environment
variables or Docker configs.

---

## Architecture

```
Airflow container
  └── reads /run/secrets/vault_airflow_token  (Docker secret)
        └── authenticates to Vault (http://vault:8200, token auth)
              ├── secret/airflow/config/*       → fernet key, DB conn, etc.
              ├── secret/airflow/connections/*  → Airflow Connection URIs
              └── secret/airflow/variables/*    → Airflow Variable values
```

---

## Vault Secret Paths (KV v2)

| Vault path | Airflow config key |
|---|---|
| `secret/airflow/config/fernet-key` | `AIRFLOW__CORE__FERNET_KEY` |
| `secret/airflow/config/api-secret-key` | `AIRFLOW__API__SECRET_KEY` |
| `secret/airflow/config/sql-alchemy-conn` | `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN` |
| `secret/airflow/config/broker-url` | `AIRFLOW__CELERY__BROKER_URL` |
| `secret/airflow/config/result-backend` | `AIRFLOW__CELERY__RESULT_BACKEND` |
| `secret/airflow/connections/seaweedfs_logs` | S3-compatible remote log connection |
| `secret/airflow/connections/<conn_id>` | Any Airflow Connection |
| `secret/airflow/variables/<key>` | Any Airflow Variable |

---

## Bootstrap (first deploy)

```bash
# 1. Initialise Vault (run once after vault service is healthy)
docker exec -it $(docker ps -q -f name=vault) vault operator init
# Save the 5 unseal keys and root token — they cannot be recovered.

# 2. Unseal Vault (required after every Vault restart — use 3 of the 5 keys)
docker exec -it $(docker ps -q -f name=vault) vault operator unseal   # repeat 3x

# 3. Enable the KV v2 secrets engine
vault secrets enable -path=secret kv-v2

# 4. Create an Airflow read-only policy
vault policy write airflow-read - <<'EOF'
path "secret/data/airflow/*" {
  capabilities = ["read"]
}
EOF

# 5. Create a token bound to that policy (1-year TTL; renew before expiry)
AIRFLOW_TOKEN=$(vault token create \
  -policy=airflow-read -no-default-policy -ttl=8760h \
  -format=json | jq -r '.auth.client_token')

# 6. Store the token as a Docker secret
echo -n "$AIRFLOW_TOKEN" | docker secret create vault_airflow_token -

# 7. Write all required infrastructure secrets
vault kv put secret/airflow/config/fernet-key \
  value="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
vault kv put secret/airflow/config/api-secret-key   value="$(openssl rand -hex 32)"
vault kv put secret/airflow/config/sql-alchemy-conn \
  value="postgresql+psycopg2://airflow:<pw>@postgres:5432/airflow"
vault kv put secret/airflow/config/broker-url       value="redis://:@redis:6379/0"
vault kv put secret/airflow/config/result-backend \
  value="db+postgresql://airflow:<pw>@postgres:5432/airflow"

# 8. Write the SeaweedFS remote-logging connection
vault kv put secret/airflow/connections/seaweedfs_logs \
  value="aws://<key>:<secret>@seaweedfs:8333?endpoint_url=http%3A%2F%2Fseaweedfs%3A8333&region_name=us-east-1"
```

---

## Airflow Configuration Reference

Configured in `infra/docker-stack/compose/airflow.yaml` via `x-airflow-common`:

```yaml
AIRFLOW__SECRETS__BACKEND: airflow.providers.hashicorp.secrets.vault.VaultBackend
AIRFLOW__SECRETS__BACKEND_KWARGS: >-
  {"connections_path": "airflow/connections",
   "variables_path": "airflow/variables",
   "config_path": "airflow/config",
   "url": "http://vault:8200",
   "auth_type": "token"}

# Infrastructure secrets resolved via the backend at container startup:
AIRFLOW__CORE__FERNET_KEY_SECRET:           fernet-key
AIRFLOW__API__SECRET_KEY_SECRET:            api-secret-key
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_SECRET: sql-alchemy-conn
AIRFLOW__CELERY__BROKER_URL_SECRET:         broker-url
AIRFLOW__CELERY__RESULT_BACKEND_SECRET:     result-backend
```

`VAULT_TOKEN` is injected by `airflow-entrypoint.sh` from the `vault_airflow_token`
Docker secret at `/run/secrets/vault_airflow_token`.

---

## DAG Connections and Variables

```python
from airflow.hooks.base import BaseHook
from airflow.models import Variable

conn = BaseHook.get_connection("my_postgres")  # fetches from Vault on demand
val  = Variable.get("output_bucket")           # fetches from Vault on demand
```

**Lookup precedence:** Vault backend → environment variables → metastore DB.

`Variable.set()` and `Connection.save()` always write to the metastore — use the
Vault CLI to manage secrets that should come from Vault.

---

## Adding a New Connection

```bash
vault kv put secret/airflow/connections/my_postgres \
  value="postgresql://user:pass@db-host:5432/mydb"
```

No service restart required — the next task access picks up the new value.

---

## Key Rotation

### Infrastructure secrets (Fernet key, DB password, etc.)

These are resolved **once at container startup**. A service restart is required after rotation.

**Fernet key rotation requires a transition period** to avoid making existing encrypted
DB values unreadable:

```bash
OLD_KEY=$(vault kv get -field=value secret/airflow/config/fernet-key)
NEW_KEY=$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')

# Step 1: set transition key (new,old) and restart all services
vault kv put secret/airflow/config/fernet-key value="${NEW_KEY},${OLD_KEY}"
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker

# Step 2: re-encrypt all metastore values
docker exec $(docker ps -q -f name=data-platform_airflow-worker | head -1) \
  airflow rotate-fernet-key

# Step 3: set only the new key and restart again
vault kv put secret/airflow/config/fernet-key value="$NEW_KEY"
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker
```

### Vault token rotation

```bash
NEW_TOKEN=$(vault token create \
  -policy=airflow-read -no-default-policy -ttl=8760h \
  -format=json | jq -r '.auth.client_token')

# Docker Swarm requires remove + re-create for secrets
echo -n "$NEW_TOKEN" | docker secret create vault_airflow_token_v2 -
for svc in airflow-apiserver airflow-scheduler airflow-dag-processor \
           airflow-triggerer airflow-worker airflow-init; do
  docker service update \
    --secret-rm vault_airflow_token \
    --secret-add source=vault_airflow_token_v2,target=vault_airflow_token \
    data-platform_${svc}
done
docker secret rm vault_airflow_token
docker secret rename vault_airflow_token_v2 vault_airflow_token
```

---

## Secret Scope Per Service

| Secret | API server | Scheduler | DAG processor | Worker | Triggerer | git-sync |
|---|---|---|---|---|---|---|
| `vault_airflow_token` | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `gitsync_ssh_key` | — | — | — | — | — | ✅ |
| `gitsync_known_hosts` (config) | — | — | — | — | — | ✅ |

---

## Caveats

- **Infrastructure `_SECRET` vars are startup-only.** Rotating them in Vault requires a service restart.
- **DAG connections and variables are on-demand.** Updates to Vault are picked up immediately.
- **`Variable.set()` writes to the metastore, not Vault.** It will shadow the Vault value.
- **Long-lived workers may cache connections.** Force a worker restart after rotating DB credentials if immediate propagation is needed.
