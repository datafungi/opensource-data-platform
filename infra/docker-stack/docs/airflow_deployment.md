# Airflow Deployment

### Docker Swarm — via Ansible from the local machine

|                    |                                         |
|--------------------|-----------------------------------------|
| **Scope**          | Apache Airflow 3.x on Docker Swarm      |
| **Applies to**     | `deploy-airflow.yml`                    |
| **Classification** | Internal / Operational                  |

---

## Prerequisites

- **Databases stack is running.** `deploy-databases.yml` must have completed
  successfully — Postgres and Redis must be healthy on the `data-platform`
  overlay network.
- **Airflow image built and pushed** to a registry reachable from all three
  cluster nodes.
- **`az login` active** on this machine with access to the Key Vault.
- **Ansible collection installed:**

```bash
cd infra/docker-stack/ansible
ansible-galaxy collection install -r requirements.yml
```

---

## Building the image

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

DAGs are baked into the image at build time. Rebuild and redeploy to update
DAGs.

---

## Running the playbook

```bash
cd infra/docker-stack/ansible
ansible-playbook deploy-airflow.yml
```

You will be prompted for:

| Prompt | Notes |
|---|---|
| Airflow image | Full image reference, e.g. `ghcr.io/org/airflow:3.2.0-20260424` |
| Airflow admin password | First deployment only — leave blank on re-runs |

Both can be passed directly to skip the prompts:

```bash
ansible-playbook deploy-airflow.yml \
  -e airflow_image=<registry>/airflow:3.2.0-<date>
```

---

## What the playbook does

**Play 1 — localhost:** Reads the Airflow DB password from Key Vault, then
populates the four Airflow-specific Key Vault secrets if they do not already
exist:

| Key Vault secret | Created by | Value |
|---|---|---|
| `airflow-config-fernet-key` | Ansible (generated once) | Random Fernet key |
| `airflow-config-api-secret-key` | Ansible (generated once) | `openssl rand -hex 32` |
| `airflow-config-broker-url` | Ansible (always set) | `redis://redis:6379/0` |
| `airflow-config-result-backend` | Ansible (always set) | `db+postgresql://airflow:<pw>@postgres/airflow` |

The fernet key and API secret key are generated once and never overwritten on
subsequent runs. The broker URL and result backend are always written because
they are deterministic and depend on the DB password.

**Play 2 — node-1 (swarm_primary):**
1. Installs `python3-docker` via apt (required by `community.docker` modules).
2. Reads the cluster managed identity client ID via `az identity show` and
   creates the `azure_mi_client_id` Docker secret.
3. Creates the `airflow_entrypoint` Docker config from
   `scripts/airflow-entrypoint.sh`.
4. Copies `compose/airflow-init.yaml` and `compose/airflow.yaml` to
   `/opt/stacks/` on node-1.
5. Deploys the init stack and waits for it to reach `Complete` state.
6. Deploys the main Airflow stack. Swarm removes the init service
   automatically since it is not in `airflow.yaml`.

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

## Services and placement

| Service | Replicas | Placement | Port |
|---|---|---|---|
| `airflow-apiserver` | 1 | any node | 8080 |
| `airflow-scheduler` | 1 | node1 | — |
| `airflow-dag-processor` | 1 | node1 | — |
| `airflow-triggerer` | 1 | node1 | — |
| `airflow-worker` | global (node2, node3) | `nodename != node1` | — |
| `airflow-flower` | 1 | any node | 5555 |

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

The Key Vault backend resolves infrastructure secrets (`_SECRET` env vars)
once at container startup, and DAG connections and variables on demand.

See `docs/airflow_secrets_management.md` for the full secrets architecture.

---

## Updating the image (re-deployments)

```bash
cd infra/docker-stack/ansible
ansible-playbook deploy-airflow.yml \
  -e airflow_image=<registry>/airflow:3.2.0-<new-date>
```

Leave the admin password prompt blank — the user already exists. The init
service redeploys (DB migration is idempotent), then the main stack is updated
with the new image via a rolling restart.
