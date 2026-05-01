# HashiCorp Vault — Setup and Operations

> **Note:** OpenBao is now the default secrets manager for this platform.
> See [`openbao_setup.md`](openbao_setup.md) for the recommended procedure.
> This document is retained for teams that prefer HashiCorp Vault.

Vault runs as a single-replica Docker Swarm service on node1 (the stateful node),
with file storage backed by GlusterFS at `/mnt/gluster/vault-data`.

---

## First-Time Bootstrap

### 1. Deploy the stack

```bash
docker config create vault_config infra/docker-stack/config/vault.hcl
docker stack deploy -c infra/docker-stack/compose/hashicorp-vault.yaml data-platform
```

The Vault service starts in a **sealed** state. All dependent services (Airflow)
will fail to retrieve secrets until Vault is unsealed.

### 2. Initialise Vault

Run once. Generates 5 unseal keys and a root token.

```bash
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator init
```

**Save the output securely** — the unseal keys and root token are shown only once
and cannot be recovered. Store them in an offline encrypted location (e.g., a
password manager or printed paper in a safe).

### 3. Unseal Vault

Vault requires 3 of the 5 unseal keys (Shamir secret sharing). Run three times
with a different key each time:

```bash
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator unseal
# Enter unseal key 1...
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator unseal
# Enter unseal key 2...
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator unseal
# Enter unseal key 3...
```

`vault status` should now show `Sealed: false`.

### 4. Enable KV v2 secrets engine

```bash
export VAULT_ADDR=http://node1-ip:8200
export VAULT_TOKEN=<root-token>

vault secrets enable -path=secret kv-v2
```

### 5. Create the Airflow read policy

```bash
vault policy write airflow-read - <<'EOF'
path "secret/data/airflow/*" {
  capabilities = ["read"]
}
EOF
```

### 6. Create and store the Airflow token

```bash
AIRFLOW_TOKEN=$(vault token create \
  -policy=airflow-read -no-default-policy -ttl=8760h \
  -format=json | jq -r '.auth.client_token')

# Store as a Docker secret
echo -n "$AIRFLOW_TOKEN" | docker secret create vault_airflow_token -
```

### 7. Write all required secrets

See `docs/airflow_secrets_management.md` for the full list of paths and values.

---

## Vault Config File

Create `infra/docker-stack/config/vault.hcl` (this file is deployed as a Docker config):

```hcl
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

ui = true
```

---

## Unsealing After a Vault Restart

Vault seals itself on restart. Whenever the Vault container restarts (node reboot,
service update), unseal it again with 3 of the 5 keys:

```bash
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator unseal
```

To reduce operational burden, consider storing unseal keys in a Makefile target or
Ansible task that reads keys from an offline-encrypted store.

---

## Auto-Unseal (Optional — Advanced)

For environments that cannot tolerate manual unseal on restart, Vault supports
**Transit Auto-Unseal**: a second "transit" Vault instance wraps the unseal keys.
This requires running a second Vault (ideally outside the Swarm cluster).
Document this as a future enhancement if needed.

---

## Prometheus Metrics

Enable Vault's Prometheus metrics endpoint (add to `vault.hcl`):

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}
```

Scrape target: `http://vault:8200/v1/sys/metrics?format=prometheus`
Add to `infra/docker-stack/compose/prometheus/prometheus.yml`.
