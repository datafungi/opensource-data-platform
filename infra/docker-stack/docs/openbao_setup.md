# OpenBao — Production Setup and Operations

OpenBao is the secrets manager for this platform. It runs as a single-replica Docker Swarm
service on node1 (the stateful node), with file storage backed by GlusterFS at
`/mnt/gluster/openbao-data`.

---

## Architecture

```
[Tailscale device]
      │  WireGuard (UDP 41641)
      ▼
[Tailscale VM — 10.54.0.4]
      │  VNet-internal routing
      ▼
[node1 — 10.54.1.10]
  openbao service  →  http://openbao:8200  (overlay network, internal only)
                   →  http://10.54.1.10:8200  (host port, tailnet only)
  GlusterFS mount  →  /mnt/gluster/openbao-data  (persistent, replicated)
```

**TLS is disabled.** All access to port 8200 flows through the Tailscale tailnet
(`10.54.0.0/24 → 10.54.1.0/24`). There is no direct internet path to OpenBao.

**Auth method: AppRole.** Services (e.g., Airflow) authenticate with a `role_id`
(Docker config, low-sensitivity) and `secret_id` (Docker secret, rotatable independently).
This avoids the long-lived service token approach and lets each credential be rotated
without redeploying the other.

---

## HCL Configuration

The config file lives at `infra/docker-stack/config/openbao.hcl` and is uploaded as a
Docker config before first deploy:

```bash
docker config create openbao_config infra/docker-stack/config/openbao.hcl
```

Key decisions in the config:

| Parameter                   | Value           | Reason                                                     |
|-----------------------------|-----------------|------------------------------------------------------------|
| `storage "file"`            | `/openbao/data` | GlusterFS bind mount; no Raft peers needed for single node |
| `tls_disable = true`        | —               | Tailscale handles transport encryption                     |
| `prometheus_retention_time` | `30s`           | Scraped by Prometheus every 15s                            |
| `audit "file" "stdout"`     | `/dev/stdout`   | Docker/journald collects and rotates audit logs            |

---

## First-Time Bootstrap

### 1. Create the Docker config and deploy

```bash
docker config create openbao_config infra/docker-stack/config/openbao.hcl
docker stack deploy -c infra/docker-stack/compose/openbao.yaml data-platform
```

OpenBao starts in a **sealed** state. Dependent services (Airflow) will fail to read
secrets until it is unsealed.

### 2. Initialise OpenBao

Run once. Generates 5 unseal keys and 1 initial root token (Shamir 3-of-5 scheme).

```bash
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator init
```

**Save the output securely.** The 5 unseal keys and root token are shown only once and
cannot be recovered. Store them in an offline encrypted store (password manager or printed
paper in a safe). Never commit them to git.

### 3. Unseal OpenBao

Requires any 3 of the 5 keys. Run three times with a different key each time:

```bash
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator unseal
# Enter key 1…
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator unseal
# Enter key 2…
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator unseal
# Enter key 3…
```

`bao status` should now show `Sealed: false`.

### 4. Enable the audit device

The HCL config declares the audit device statically, but it must also be enabled via the
API on first boot (OpenBao activates static audit stanzas at init time in v2.x, but
running this manually is safe and idempotent):

```bash
export BAO_ADDR=http://10.54.1.10:8200
export BAO_TOKEN=<root-token>

bao audit enable file file_path=/dev/stdout
```

### 5. Enable the KV v2 secrets engine

```bash
bao secrets enable -path=secret kv-v2
```

### 6. Create the Airflow read policy

```bash
bao policy write airflow-read - <<'EOF'
path "secret/data/airflow/*" {
  capabilities = ["read"]
}
EOF
```

### 7. Enable AppRole and create the Airflow role

```bash
bao auth enable approle

bao write auth/approle/role/airflow \
  policies=airflow-read \
  token_ttl=1h \
  token_max_ttl=4h \
  token_no_default_policy=true \
  secret_id_ttl=0        # non-expiring; rotate manually
```

`token_ttl=1h` means Airflow renews its token every hour. `secret_id_ttl=0` means the
secret ID does not expire on its own — rotate it manually using the procedure below.

### 8. Fetch and store the AppRole credentials as Docker secrets

```bash
ROLE_ID=$(bao read -field=role_id auth/approle/role/airflow/role-id)
SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/airflow/secret-id)

echo -n "$ROLE_ID"   | docker secret create openbao_airflow_role_id -
echo -n "$SECRET_ID" | docker secret create openbao_airflow_secret_id -
```

`role_id` is not sensitive (it's like a username) but storing it as a Docker secret keeps
the deployment uniform.

### 9. Write the infrastructure secrets

```bash
bao kv put secret/airflow/config/fernet-key \
  value="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"

bao kv put secret/airflow/config/api-secret-key \
  value="$(openssl rand -hex 32)"

bao kv put secret/airflow/config/sql-alchemy-conn \
  value="postgresql+psycopg2://airflow:<pw>@postgres:5432/airflow"

bao kv put secret/airflow/config/broker-url \
  value="redis://:@redis:6379/0"

bao kv put secret/airflow/config/result-backend \
  value="db+postgresql://airflow:<pw>@postgres:5432/airflow"

bao kv put secret/airflow/connections/seaweedfs_logs \
  value="aws://<key>:<secret>@seaweedfs:8333?endpoint_url=http%3A%2F%2Fseaweedfs%3A8333&region_name=us-east-1"
```

Replace `<pw>`, `<key>`, `<secret>` with actual values. Never commit them to git.

---

## Airflow Configuration

Update `infra/docker-stack/compose/airflow.yaml` (`x-airflow-common`) to point at
OpenBao using AppRole auth:

```yaml
AIRFLOW__SECRETS__BACKEND: airflow.providers.hashicorp.secrets.vault.VaultBackend
AIRFLOW__SECRETS__BACKEND_KWARGS: >-
  {"connections_path": "airflow/connections",
   "variables_path":   "airflow/variables",
   "config_path":      "airflow/config",
   "url":              "http://openbao:8200",
   "auth_type":        "approle",
   "role_id_env_var":  "AIRFLOW__SECRETS__VAULT_ROLE_ID",
   "secret_id_env_var": "AIRFLOW__SECRETS__VAULT_SECRET_ID"}
```

Inject the credentials via the entrypoint (read from Docker secrets at
`/run/secrets/openbao_airflow_role_id` and `/run/secrets/openbao_airflow_secret_id`),
then export as the env vars named above.

---

## Unsealing After a Restart

OpenBao seals itself on container restart. After any node reboot or service update,
unseal with 3 keys:

```bash
docker exec -it $(docker ps -q -f name=data-platform_openbao) bao operator unseal
```

---

## Prometheus Metrics

Scrape target: `http://openbao:8200/v1/sys/metrics?format=prometheus`

Add to `infra/docker-stack/compose/prometheus/prometheus.yml`:

```yaml
- job_name: openbao
  metrics_path: /v1/sys/metrics
  params:
    format: [prometheus]
  bearer_token: <prometheus-read-token>
  static_configs:
    - targets: ["openbao:8200"]
```

Create a read-only Prometheus token:

```bash
bao policy write prometheus-metrics - <<'EOF'
path "sys/metrics" {
  capabilities = ["read"]
}
EOF

bao token create -policy=prometheus-metrics -no-default-policy \
  -ttl=8760h -format=json | jq -r '.auth.client_token'
```

---

## Credential Rotation

### Rotate the AppRole secret_id

Secret IDs are the higher-sensitivity half of AppRole credentials. Rotate periodically
(recommended: every 90 days) or immediately after a suspected compromise.

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

### Rotate the Fernet key

Fernet key rotation requires a transition window to avoid decryption failures on
existing encrypted DB values. Infrastructure secrets are resolved at container startup,
so a service restart is required.

```bash
OLD_KEY=$(bao kv get -field=value secret/airflow/config/fernet-key)
NEW_KEY=$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')

# Step 1: transition period (new,old) — restart all Airflow services
bao kv put secret/airflow/config/fernet-key value="${NEW_KEY},${OLD_KEY}"
for svc in airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer airflow-worker; do
  docker service update --force data-platform_${svc}
done

# Step 2: re-encrypt all metastore values with the new key
docker exec $(docker ps -q -f name=data-platform_airflow-worker | head -1) \
  airflow rotate-fernet-key

# Step 3: drop the old key — restart again
bao kv put secret/airflow/config/fernet-key value="$NEW_KEY"
for svc in airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer airflow-worker; do
  docker service update --force data-platform_${svc}
done
```

---

## Adding a New Secret

```bash
# Connection (picked up immediately by Airflow — no restart needed)
bao kv put secret/airflow/connections/my_postgres \
  value="postgresql://user:pass@db-host:5432/mydb"

# Variable
bao kv put secret/airflow/variables/output_bucket value="iceberg-warehouse"
```

---

## Secret Paths Reference

| OpenBao path                             | Airflow config key                    |
|------------------------------------------|---------------------------------------|
| `secret/airflow/config/fernet-key`       | `AIRFLOW__CORE__FERNET_KEY`           |
| `secret/airflow/config/api-secret-key`   | `AIRFLOW__API__SECRET_KEY`            |
| `secret/airflow/config/sql-alchemy-conn` | `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN` |
| `secret/airflow/config/broker-url`       | `AIRFLOW__CELERY__BROKER_URL`         |
| `secret/airflow/config/result-backend`   | `AIRFLOW__CELERY__RESULT_BACKEND`     |
| `secret/airflow/connections/<conn_id>`   | Any Airflow Connection                |
| `secret/airflow/variables/<key>`         | Any Airflow Variable                  |

---

## Future: Auto-Unseal via Transit

Manually entering 3 unseal keys after every restart is the main operational burden.
OpenBao supports Transit Auto-Unseal: a second OpenBao instance (ideally outside the
Swarm cluster, e.g., a small cloud VM) wraps the unseal keys so the primary unseals
automatically on restart.

This requires a separate "transit" OpenBao server, a Transit secrets engine, and an
`seal "transit"` stanza in `openbao.hcl`. Document as a follow-up when uptime SLA
requirements demand it.
