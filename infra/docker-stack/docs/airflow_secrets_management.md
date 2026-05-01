# Airflow Secrets Management

Airflow resolves connections, variables, and configuration values at runtime from
**OpenBao** (KV v2 secrets engine, MPL 2.0). No credentials are stored in environment
variables or Docker configs.

---

## Architecture

```
Airflow container
  ├── reads /run/secrets/openbao_airflow_role_id    (Docker secret)
  └── reads /run/secrets/openbao_airflow_secret_id  (Docker secret)
        └── authenticates to OpenBao (http://openbao:8200, AppRole auth)
              ├── secret/airflow/config/*       → fernet key, DB conn, etc.
              ├── secret/airflow/connections/*  → Airflow Connection URIs
              └── secret/airflow/variables/*    → Airflow Variable values
```

---

## Vault Secret Paths (KV v2)

| Vault path                                  | Airflow config key                    |
|---------------------------------------------|---------------------------------------|
| `secret/airflow/config/fernet-key`          | `AIRFLOW__CORE__FERNET_KEY`           |
| `secret/airflow/config/api-secret-key`      | `AIRFLOW__API__SECRET_KEY`            |
| `secret/airflow/config/sql-alchemy-conn`    | `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN` |
| `secret/airflow/config/broker-url`          | `AIRFLOW__CELERY__BROKER_URL`         |
| `secret/airflow/config/result-backend`      | `AIRFLOW__CELERY__RESULT_BACKEND`     |
| `secret/airflow/connections/seaweedfs_logs` | S3-compatible remote log connection   |
| `secret/airflow/connections/<conn_id>`      | Any Airflow Connection                |
| `secret/airflow/variables/<key>`            | Any Airflow Variable                  |

---

## Bootstrap (first deploy)

See `docs/openbao_setup.md` for the full procedure. The abbreviated steps are:

```bash
# 1. Initialise OpenBao (run once after the service is healthy)
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator init
# Save the 5 unseal keys and root token — they cannot be recovered.

# 2. Unseal OpenBao (required after every restart — use 3 of the 5 keys)
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator unseal  # repeat 3x

# 3. Enable the KV v2 secrets engine
bao secrets enable -path=secret kv-v2

# 4. Create an Airflow read-only policy
bao policy write airflow-read - <<'EOF'
path "secret/data/airflow/*" {
  capabilities = ["read"]
}
EOF

# 5. Enable AppRole and create the Airflow role
bao auth enable approle
bao write auth/approle/role/airflow \
  policies=airflow-read token_ttl=1h token_max_ttl=4h \
  token_no_default_policy=true secret_id_ttl=0

# 6. Store the AppRole credentials as Docker secrets
ROLE_ID=$(bao read -field=role_id auth/approle/role/airflow/role-id)
SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/airflow/secret-id)
echo -n "$ROLE_ID"   | docker secret create openbao_airflow_role_id -
echo -n "$SECRET_ID" | docker secret create openbao_airflow_secret_id -

# 7. Write all required infrastructure secrets
bao kv put secret/airflow/config/fernet-key \
  value="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
bao kv put secret/airflow/config/api-secret-key   value="$(openssl rand -hex 32)"
bao kv put secret/airflow/config/sql-alchemy-conn \
  value="postgresql+psycopg2://airflow:<pw>@postgres:5432/airflow"
bao kv put secret/airflow/config/broker-url       value="redis://:@redis:6379/0"
bao kv put secret/airflow/config/result-backend \
  value="db+postgresql://airflow:<pw>@postgres:5432/airflow"

# 8. Write the SeaweedFS remote-logging connection
bao kv put secret/airflow/connections/seaweedfs_logs \
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
   "url": "http://openbao:8200",
   "auth_type": "approle",
   "role_id_env_var":   "AIRFLOW__SECRETS__VAULT_ROLE_ID",
   "secret_id_env_var": "AIRFLOW__SECRETS__VAULT_SECRET_ID"}

# Infrastructure secrets resolved via the backend at container startup:
AIRFLOW__CORE__FERNET_KEY_SECRET:           fernet-key
AIRFLOW__API__SECRET_KEY_SECRET:            api-secret-key
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_SECRET: sql-alchemy-conn
AIRFLOW__CELERY__BROKER_URL_SECRET:         broker-url
AIRFLOW__CELERY__RESULT_BACKEND_SECRET:     result-backend
```

`AIRFLOW__SECRETS__VAULT_ROLE_ID` and `AIRFLOW__SECRETS__VAULT_SECRET_ID` are injected
by `airflow-entrypoint.sh` from Docker secrets at `/run/secrets/openbao_airflow_role_id`
and `/run/secrets/openbao_airflow_secret_id`.

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
bao kv put secret/airflow/connections/my_postgres \
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
OLD_KEY=$(bao kv get -field=value secret/airflow/config/fernet-key)
NEW_KEY=$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')

# Step 1: set transition key (new,old) and restart all services
bao kv put secret/airflow/config/fernet-key value="${NEW_KEY},${OLD_KEY}"
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker

# Step 2: re-encrypt all metastore values
docker exec $(docker ps -q -f name=data-platform_airflow-worker | head -1) \
  airflow rotate-fernet-key

# Step 3: set only the new key and restart again
bao kv put secret/airflow/config/fernet-key value="$NEW_KEY"
docker service update --force data-platform_airflow-apiserver
docker service update --force data-platform_airflow-scheduler
docker service update --force data-platform_airflow-worker
```

### AppRole secret_id rotation

Rotate the `secret_id` periodically (recommended: every 90 days) or after a suspected
compromise. The `role_id` rarely needs rotation.

```bash
NEW_SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/airflow/secret-id)

# Docker Swarm requires remove + re-create for secrets
echo -n "$NEW_SECRET_ID" | docker secret create openbao_airflow_secret_id_v2 -
for svc in airflow-apiserver airflow-scheduler airflow-dag-processor \
           airflow-triggerer airflow-worker airflow-init; do
  docker service update \
    --secret-rm openbao_airflow_secret_id \
    --secret-add source=openbao_airflow_secret_id_v2,target=openbao_airflow_secret_id \
    data-platform_${svc}
done
docker secret rm openbao_airflow_secret_id
docker secret rename openbao_airflow_secret_id_v2 openbao_airflow_secret_id
```

---

## Secret Scope Per Service

| Secret                         | API server | Scheduler | DAG processor | Worker | Triggerer | git-sync |
|--------------------------------|------------|-----------|---------------|--------|-----------|----------|
| `openbao_airflow_role_id`      | ✅          | ✅         | ✅             | ✅      | ✅         | —        |
| `openbao_airflow_secret_id`    | ✅          | ✅         | ✅             | ✅      | ✅         | —        |
| `gitsync_ssh_key`              | —          | —         | —             | —      | —         | ✅        |
| `gitsync_known_hosts` (config) | —          | —         | —             | —      | —         | ✅        |

---

## Caveats

- **Infrastructure `_SECRET` vars are startup-only.** Rotating them in Vault requires a service restart.
- **DAG connections and variables are on-demand.** Updates to Vault are picked up immediately.
- **`Variable.set()` writes to the metastore, not Vault.** It will shadow the Vault value.
- **Long-lived workers may cache connections.** Force a worker restart after rotating DB credentials if immediate propagation is needed.
