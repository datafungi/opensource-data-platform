# Airflow Deployment

### Docker Swarm — via Ansible from the local machine

|                    |                                    |
|--------------------|------------------------------------|
| **Scope**          | Apache Airflow 3.x on Docker Swarm |
| **Applies to**     | `deploy-airflow.yml`               |
| **Classification** | Internal / Operational             |

---

## Prerequisites

- **Databases stack is running.** `deploy-databases.yml` must have completed
  successfully — Postgres and Redis must be healthy on the `data-platform`
  overlay network.
- **Airflow image built and pushed** to a registry reachable from all three
  cluster nodes.
- **`az login` active** on this machine with access to the Key Vault.
- **`group_vars/all.yml` populated:**
  - `keyvault_name` — from `terraform output -raw key_vault_name`
  - `storage_account_name` — from `terraform output -raw backup_storage_account_name`
  - `repo_url` — SSH URL of the git repository (e.g. `git@github.com:org/repo.git`)
  - `repo_ref` — branch or tag to sync (default: `main`)
- **SSH deploy key in Key Vault** (`gitsync-ssh-key`): private key of an
  ed25519 deploy key added to the GitHub repo with read-only access.
  See [DAG Delivery](#dag-delivery).
- **Ansible collection installed:**

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-galaxy collection install -r requirements.yml
```

---

## Building the image

The Airflow image contains the Python runtime and provider dependencies. DAGs
and plugins are **not** baked in — they are delivered at runtime by git-sync.

From the repo root:

```bash
TAG="$(date +%Y%m%d)"
IMAGE="<your-registry>/airflow:3.2.0-${TAG}"

docker build \
  -f infra/images/airflow.Dockerfile \
  -t "${IMAGE}" \
  .

docker push "${IMAGE}"
```

Rebuild the image only when Python dependencies change. To update DAGs or
plugins, push to the git repository — no image rebuild required.

---

## Running the playbook

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-playbook deploy-airflow.yml
```

You will be prompted for:

| Prompt                 | Notes                                                           |
|------------------------|-----------------------------------------------------------------|
| Airflow image          | Full image reference, e.g. `ghcr.io/org/airflow:3.2.0-20260424` |
| Airflow admin password | First deployment only — leave blank on re-runs                  |

Both can be passed directly to skip the prompts:

```bash
ansible-playbook deploy-airflow.yml \
  -e airflow_image=<registry>/airflow:3.2.0-<date>
```

---

## What the playbook does

**Play 1 — localhost:** Reads the Airflow DB password from Key Vault, then
populates the Airflow-specific Key Vault secrets:

| Key Vault secret                      | Created by               | Value                                           |
|---------------------------------------|--------------------------|-------------------------------------------------|
| `airflow-config-fernet-key`           | Ansible (generated once) | Random Fernet key                               |
| `airflow-config-api-secret-key`       | Ansible (generated once) | `openssl rand -hex 32`                          |
| `airflow-config-broker-url`           | Ansible (always set)     | `redis://redis:6379/0`                          |
| `airflow-config-result-backend`       | Ansible (always set)     | `db+postgresql://airflow:<pw>@postgres/airflow` |
| `airflow-connections-azure-blob-logs` | Ansible (always set)     | `wasb://<storage_account_name>`                 |

The fernet key and API secret key are generated once and never overwritten on
subsequent runs. The remaining three are always written because they are
deterministic.

**Play 2 — all nodes (swarm_managers):** Creates `/opt/dags` on every cluster
node with ownership `65533:65533` (git-sync's process UID/GID) so the
git-sync container can initialise and write its working directory.

**Play 3 — node-1 (swarm_primary):**
1. Installs `python3-docker` via apt (required by `community.docker` modules).
2. Reads the cluster managed identity client ID via `az identity show` and
   creates the `azure_mi_client_id` Docker secret.
3. Creates the `airflow_entrypoint` Docker config from
   `scripts/airflow-entrypoint.sh`.
4. Downloads `gitsync-ssh-key` from Key Vault via `az keyvault secret download`
   (preserves exact file content), creates the `gitsync_ssh_key` Docker secret,
   then removes the temp file.
5. Creates the `gitsync_known_hosts` Docker config containing GitHub's current
   host keys (ed25519, ecdsa, rsa).
6. Copies `compose/airflow-init.yaml` and `compose/airflow.yaml` to
   `/opt/stacks/` on node-1.
7. Deploys the init stack and waits for it to reach `Complete` state.
8. Deploys the main Airflow stack.

---

## Init stack

`compose/airflow-init.yaml` deploys a single one-shot service
(`restart_policy: condition: none`) that:

1. Runs `airflow db migrate` via the `_AIRFLOW_DB_MIGRATE=true` env var
   (processed by the Airflow Docker entrypoint before executing any command).
2. Creates the admin user via `_AIRFLOW_WWW_USER_CREATE=true` — only when
   `AIRFLOW_CREATE_ADMIN=true`, which the Ansible playbook sets only when an
   admin password was provided.

The init service uses the Azure Key Vault backend to resolve the DB connection
string and Fernet key via the `_SECRET` mechanism — no credentials are passed
in plain text.

On re-runs the init service always redeploys but skips user creation (password
prompt left blank → `AIRFLOW_CREATE_ADMIN=false`). DB migration is idempotent.

### Known issue: `airflow users create` fails in Airflow 3.x

Running `airflow users create` directly in Airflow 3.x raises:

```
AttributeError: 'AirflowSecurityManagerV2' object has no attribute 'find_role'
```

The init service works around this by using `_AIRFLOW_WWW_USER_CREATE=true`
via the Docker entrypoint, which uses a different internal code path.

---

## DAG delivery

DAGs and plugins are delivered to all cluster nodes via **git-sync** — a
lightweight service that continuously syncs the git repository into `/opt/dags`
on each node.

### How it works

- git-sync runs as a `mode: global` service — one instance on every node.
- It clones the repository into `/opt/dags/.worktrees/<rev>/` and atomically
  updates the symlink `/opt/dags/repo` to point to the latest revision.
- All Airflow services mount `/opt/dags` as a read-only bind mount at `/dags`
  inside the container.
- The dag-processor scans `/dags/repo/airflow/dags/` and workers import task
  code from the same path.
- Plugins live at `airflow/dags/plugins/` in the repo, mapped to
  `/dags/repo/airflow/dags/plugins/` inside containers.
- Sync interval: **60 seconds**. DAG changes are live within one sync cycle
  with no service restart.

```
/opt/dags/
  repo  →  .worktrees/<rev-hash>/    (atomic symlink, updated each sync)
  .worktrees/<rev-hash>/
    airflow/
      dags/
        plugins/
        <dag-files>
```

### SSH deploy key setup

```bash
# 1. Generate a key pair
ssh-keygen -t ed25519 -C "git-sync deploy key" -f /tmp/gitsync_deploy_key -N ""

# 2. Add the public key to GitHub:
#    Repo → Settings → Deploy keys → Add deploy key (read-only)
cat /tmp/gitsync_deploy_key.pub

# 3. Store the private key in Key Vault
az keyvault secret set \
  --vault-name <keyvault-name> \
  --name gitsync-ssh-key \
  --file /tmp/gitsync_deploy_key

# 4. Clean up
rm /tmp/gitsync_deploy_key /tmp/gitsync_deploy_key.pub
```

The Ansible playbook reads `gitsync-ssh-key` via `az keyvault secret download`
and creates the `gitsync_ssh_key` Docker secret. GitHub's host keys are bundled
as the `gitsync_known_hosts` Docker config — no manual known_hosts setup is
required on any node.

### Updating DAGs

Push changes to the configured branch (`repo_ref`, default `main`). git-sync
picks them up within 60 seconds with no manual intervention.

Plugin changes require a worker restart because plugins are loaded at process
startup:

```bash
docker service update --force data-platform_airflow-worker
```

---

## Remote logging

Task logs are written to **Azure Blob Storage** instead of the local
filesystem. This ensures logs are accessible from the Airflow UI regardless of
which node ran the task, and persist across container restarts.

| Setting           | Value                                  |
|-------------------|----------------------------------------|
| Container         | `airflow-logs` (created by Terraform)  |
| Connection ID     | `azure_blob_logs`                      |
| Auth              | Managed identity via `AZURE_CLIENT_ID` |
| Local log cleanup | Enabled (`DELETE_LOCAL_LOGS=true`)     |

The `azure_blob_logs` connection is a `wasb://` URI stored in Key Vault as
`airflow-connections-azure-blob-logs` and resolved at runtime by the Key Vault
secrets backend. The managed identity has `Storage Blob Data Contributor` role
on the storage account, granted by Terraform.

DAG connections and variables stored in Key Vault are fetched on demand — no
restart needed after updating them.

---

## Services and placement

| Service                 | Replicas              | Placement           | Port |
|-------------------------|-----------------------|---------------------|------|
| `airflow-apiserver`     | 1                     | any node            | 8080 |
| `airflow-scheduler`     | 1                     | node1               | —    |
| `airflow-dag-processor` | 1                     | node1               | —    |
| `airflow-triggerer`     | 1                     | node1               | —    |
| `airflow-worker`        | global (node2, node3) | `nodename != node1` | —    |
| `airflow-flower`        | 1                     | any node            | 5555 |
| `git-sync`              | global (all 3 nodes)  | —                   | —    |

Workers are excluded from node-1 because node-1 hosts scheduler,
dag-processor, triggerer, Postgres, and Redis — four services pinned there
already consume most of the 8 GiB RAM budget.

Once healthy, the UI is at `http://10.54.1.10:8080` (accessible via Tailscale).

---

## Managed identity and Key Vault authentication

All Airflow services use `scripts/airflow-entrypoint.sh` as their Docker
entrypoint. The wrapper reads `azure_mi_client_id` from
`/run/secrets/azure_mi_client_id` and exports it as `AZURE_CLIENT_ID` before
exec-ing into the standard Airflow entrypoint. This allows
`DefaultAzureCredential` to select the correct user-assigned managed identity
when multiple identities are attached to the VM.

The same managed identity authenticates to:
- **Azure Key Vault** — reads infrastructure secrets and resolves DAG
  connections/variables at runtime.
- **Azure Blob Storage** — writes task logs to the `airflow-logs` container.

See `docs/airflow_secrets_management.md` for the full secrets architecture.

---

## Tearing down

To remove all running services and stale Postgres Docker secrets before a fresh
redeploy or password rotation:

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-playbook teardown.yml
```

The teardown playbook removes the `data-platform` stack, waits for all services
to exit, then removes the three Postgres Docker secrets. It does **not** remove
overlay networks, Docker configs, or non-Postgres Docker secrets
(`azure_mi_client_id`, `gitsync_ssh_key`).

After teardown, run `terraform apply` to rotate Postgres passwords, then
re-run `deploy-databases.yml` and `deploy-airflow.yml`.

---

## Updating the image (re-deployments)

```bash
cd infra/docker-stack/providers/azure/ansible
ansible-playbook deploy-airflow.yml \
  -e airflow_image=<registry>/airflow:3.2.0-<new-date>
```

Leave the admin password prompt blank — the user already exists. The init
service redeploys (DB migration is idempotent), then the main stack is updated
with the new image via a rolling restart. git-sync continues running
uninterrupted.
