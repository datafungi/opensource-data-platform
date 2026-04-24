# Postgres Deployment

### Docker Swarm — via Ansible from the local machine

|                    |                                  |
|--------------------|----------------------------------|
| **Scope**          | Postgres + Redis on Docker Swarm |
| **Applies to**     | `deploy-databases.yml`           |
| **Classification** | Internal / Operational           |

---

## Prerequisites

Run these once per environment, before the first `ansible-playbook` invocation.

### 1. Terraform apply

Generates Postgres passwords, stores them in Key Vault, and assembles the
Airflow SQL Alchemy connection string:

```bash
cd infra/docker-stack/providers/azure/terraform
terraform apply
```

### 2. Fill in group vars

Resolve the Key Vault name from Terraform output and set it in
`providers/azure/ansible/group_vars/all.yml`:

```bash
terraform output -raw key_vault_name
# → paste the value into keyvault_name: ""
```

### 3. Install the Ansible collection

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-galaxy collection install -r requirements.yml
```

### 4. SSH access via Tailscale

The playbook SSHes to `10.54.1.10` (node-1). Ensure your device is on the
tailnet and the subnet router (`10.54.0.4`) is advertising `10.54.0.0/16`.

---

## Running the playbook

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-playbook deploy-databases.yml
```

The playbook performs two plays:

**Play 1 — localhost:** reads the three Postgres passwords from Key Vault via
`az keyvault secret show`.

**Play 2 — node-1 (swarm_primary):**
1. Installs the Python Docker SDK (`python3-docker`) via apt — required by the
   `community.docker` Ansible modules.
2. Creates three Docker secrets: `postgres_superuser_password`,
   `postgres_airflow_password`, `postgres_polaris_password`.
3. Creates the `postgres_init_db` Docker config from
   `scripts/postgres-init.sh`.
4. Creates the `data-platform` overlay network if it does not exist.
5. Labels node-1 as `stateful=true` and sets `nodename` labels on all three
   nodes.
6. Copies `compose/databases.yaml` to `/opt/stacks/databases.yaml` on node-1.
7. Runs `docker stack deploy`.

---

## What Postgres init does

`scripts/postgres-init.sh` runs once on the first boot of the Postgres
container (empty data directory). It reads the application passwords from
Docker secrets and creates two users and databases:

| User      | Database  | Purpose             |
|-----------|-----------|---------------------|
| `airflow` | `airflow` | Airflow metadata DB |
| `polaris` | `polaris` | Polaris catalog     |

The superuser (`postgres`) password is set via `POSTGRES_PASSWORD_FILE` in the
compose file and is not used by application services.

---

## Overlay network

The `data-platform` overlay network is shared across all stacks (databases,
Airflow, etc.). The playbook creates it as an attachable overlay on first run.
All compose files declare it as `external: true` so Docker Swarm does not
prefix it with the stack name.

---

## Rotating Postgres passwords

Terraform manages the passwords. To rotate:

```bash
cd infra/docker-stack/providers/azure/terraform
terraform apply \
  -target=random_password.postgres_superuser \
  -target=random_password.postgres_airflow \
  -target=random_password.postgres_polaris \
  -target=azurerm_key_vault_secret.postgres_superuser_password \
  -target=azurerm_key_vault_secret.postgres_airflow_password \
  -target=azurerm_key_vault_secret.postgres_polaris_password \
  -target=azurerm_key_vault_secret.airflow_sql_alchemy_conn
```

Then delete the existing Docker secrets and re-run the playbook:

```bash
# On node-1
docker secret rm postgres_superuser_password postgres_airflow_password postgres_polaris_password
```

```bash
ansible-playbook deploy-databases.yml
```

Restart Postgres and any Airflow services to pick up the new credentials.

---

## Known deployment issues and fixes

These were encountered during initial deployment and are already applied in the
playbook and compose file.

### Python Docker SDK not installed on nodes

`community.docker` modules require the Python `docker` package on the remote
host. The `ansible` pip module cannot be used because `pip3` is not installed
by default on the Azure Ubuntu VMs. Fixed by adding a `pre_tasks` block that
installs `python3-docker` via apt:

```yaml
pre_tasks:
  - name: Install Python Docker SDK
    ansible.builtin.apt:
      name: python3-docker
      state: present
      update_cache: true
    become: true
```

### Permission denied creating /opt/stacks

`azureuser` does not have write access to `/opt/`. Fixed by adding
`become: true` to the `file` and `copy` tasks that write to `/opt/stacks/`.

### Overlay network undefined at stack deploy time

The `data-platform` network was referenced in the compose file but not
declared at the top level, causing Docker Swarm to fail with
`service redis: undefined network "data-platform"`.

Two fixes applied together:
1. Declare the network as external in `compose/databases.yaml`:
   ```yaml
   networks:
     data-platform:
       external: true
   ```
2. Create the network before deploying the stack (Ansible task using
   `community.docker.docker_network`). Without this declaration, Docker Swarm
   would prefix the network name with the stack name, producing
   `data-platform_data-platform`.
