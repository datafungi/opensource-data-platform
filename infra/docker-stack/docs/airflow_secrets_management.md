# Apache Airflow — Key Rotation & Docker Secrets Backend
### Implementation Guide for Docker Swarm Mode

|                    |                                     |
|--------------------|-------------------------------------|
| **Version**        | 1.0                                 |
| **Scope**          | Apache Airflow on Docker Swarm Mode |
| **Applies to**     | Airflow 3.x (2.x notes inline)      |
| **Classification** | Internal / Operational              |

**About This Document**

This guide covers how to rotate cryptographic secrets in Apache Airflow running in Docker Swarm Mode, and how to implement a custom Docker Swarm Secrets backend so that DAGs can retrieve connections and variables from Docker secrets at runtime. It includes manual steps, automation scripts, and a complete custom backend implementation.

---

## Table of Contents

1. [Overview & Key Concepts](#1-overview--key-concepts)
2. [Manual Key Rotation Procedures](#2-manual-key-rotation-procedures)
3. [Docker Compose Stack File](#3-docker-compose-stack-file)
4. [Custom Docker Swarm Secrets Backend](#4-custom-docker-swarm-secrets-backend)
5. [Automating Key Rotation](#5-automating-key-rotation)
6. [Important Caveats & Best Practices](#6-important-caveats--best-practices)
7. [Quick Reference Checklists](#7-quick-reference-checklists)

---

## 1. Overview & Key Concepts

### 1.1 What Needs Rotating?

Apache Airflow uses several cryptographic secrets. Each has a different scope, risk surface, and rotation procedure:

| Secret                     | Config Variable                                                           | Impact if Rotated                              | Re-encryption?                      |
|----------------------------|---------------------------------------------------------------------------|------------------------------------------------|-------------------------------------|
| **Fernet Key**             | `AIRFLOW__CORE__FERNET_KEY`                                               | Encrypted DB values unreadable without old key | ✅ Yes — run `rotate-fernet-key` CLI |
| **Webserver / API Secret** | `AIRFLOW__WEBSERVER__SECRET_KEY` (2.x) / `AIRFLOW__API__SECRET_KEY` (3.x) | All user sessions invalidated                  | ❌ No                                |
| **DB Password**            | `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN`                                     | Brief downtime during redeploy                 | ❌ No                                |
| **Celery Broker URL**      | `AIRFLOW__CELERY__BROKER_URL`                                             | Worker restart needed                          | ❌ No                                |

### 1.2 The `_CMD` Suffix — Official Support

Airflow supports a `_CMD` suffix for a specific allowlist of config keys. When set, Airflow executes the command and uses its output as the config value. This is the correct way to read Docker Swarm secrets at container startup.

> **⚠️ Important:** The `_CMD` suffix is **not** supported for all config keys. Only the following are in the allowlist:

| Config Key         | Section       | Environment Variable (`_CMD`)             |
|--------------------|---------------|-------------------------------------------|
| `fernet_key`       | `[core]`      | `AIRFLOW__CORE__FERNET_KEY_CMD`           |
| `sql_alchemy_conn` | `[database]`  | `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_CMD` |
| `secret_key` (2.x) | `[webserver]` | `AIRFLOW__WEBSERVER__SECRET_KEY_CMD`      |
| `secret_key` (3.x) | `[api]`       | `AIRFLOW__API__SECRET_KEY_CMD`            |
| `broker_url`       | `[celery]`    | `AIRFLOW__CELERY__BROKER_URL_CMD`         |
| `result_backend`   | `[celery]`    | `AIRFLOW__CELERY__RESULT_BACKEND_CMD`     |
| `smtp_password`    | `[smtp]`      | `AIRFLOW__SMTP__SMTP_PASSWORD_CMD`        |

📖 **Official documentation:** https://airflow.apache.org/docs/apache-airflow/stable/cli-and-env-variables-ref.html

### 1.3 Two Complementary Approaches

These two approaches are not mutually exclusive — use both:

| Approach               | Best For                                                               | Mechanism                                                     |
|------------------------|------------------------------------------------------------------------|---------------------------------------------------------------|
| `_CMD` env vars        | Infrastructure secrets: Fernet key, DB conn, broker URL                | Airflow reads Docker secret file at startup via shell command |
| Custom Secrets Backend | Application secrets: Airflow Connections, Variables accessed from DAGs | Python class queries `/run/secrets/` at DAG task runtime      |

---

## 2. Manual Key Rotation Procedures

### 2.1 Fernet Key Rotation

The Fernet key encrypts sensitive data stored in the metadata database (connections, variables). It is the most critical secret to manage carefully because rotating it incorrectly will make encrypted values unreadable.

> **🔑 Key Point:** Airflow supports a comma-separated list of Fernet keys. The first key encrypts new values; the rest decrypt old values. This enables zero-downtime rotation.

#### Step 1 — Generate a new Fernet key

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

#### Step 2 — Create a new Docker secret with transition value

The transition secret contains both the new and old key, comma-separated:

```bash
NEW_KEY="<paste-new-key-here>"

# Read old key value from a running container:
OLD_KEY_VALUE=$(docker exec $(docker ps -q -f name=airflow_worker) \
  sh -c 'cat /run/secrets/airflow_fernet_key')

# Create a transition secret: new,old
echo "${NEW_KEY},${OLD_KEY_VALUE}" | docker secret create airflow_fernet_transition_v2 -
```

#### Step 3 — Update stack to use transition secret

Update your docker-compose stack file to reference the new transition secret, then redeploy:

```bash
# In docker-compose.yml, update the secret reference and env var:
# environment:
#   AIRFLOW__CORE__FERNET_KEY_CMD: "cat /run/secrets/airflow_fernet_key"
# secrets:
#   - airflow_fernet_transition_v2

docker stack deploy -c docker-compose.yml airflow
```

#### Step 4 — Re-encrypt existing credentials

Once all containers are running with the transition key, run `rotate-fernet-key` to re-encrypt all DB values with the new key:

```bash
docker exec $(docker ps -q -f name=airflow_worker | head -1) \
  airflow rotate-fernet-key
```

> **✅ What this does:** The CLI re-encrypts all connections and variables in the metadata DB using the first (new) key. After this, the old key is no longer needed.

#### Step 5 — Switch to the new key only

```bash
# Create a clean secret with only the new key
echo "${NEW_KEY}" | docker secret create airflow_fernet_key_v2 -

# Update stack to use the clean new secret
docker stack deploy -c docker-compose.yml airflow

# After confirming everything works, remove the old secrets
docker secret rm airflow_fernet_key
docker secret rm airflow_fernet_transition_v2
```

---

### 2.2 Webserver / API Secret Key Rotation

This key signs user session cookies. There is no re-encryption step, but all active sessions will be invalidated when it changes.

> **⚠️ Version note:** In Airflow 2.x use `AIRFLOW__WEBSERVER__SECRET_KEY_CMD`. In Airflow 3.x this moved to `AIRFLOW__API__SECRET_KEY_CMD`.

```bash
# Generate new secret
NEW_SECRET=$(openssl rand -hex 32)

# Create new Docker secret
echo "${NEW_SECRET}" | docker secret create airflow_api_secret_v2 -

# Update stack and redeploy
docker stack deploy -c docker-compose.yml airflow

# Remove old secret after confirming login works
docker secret rm airflow_api_secret
```

---

### 2.3 Database Password Rotation

```bash
# 1. Change the password in PostgreSQL first
docker exec -it $(docker ps -q -f name=postgres) \
  psql -U postgres -c "ALTER USER airflow WITH PASSWORD 'new_password';"

# 2. Create new Docker secret with updated connection string
echo "postgresql+psycopg2://airflow:new_password@postgres/airflow" \
  | docker secret create airflow_db_conn_v2 -

# 3. Update stack
docker stack deploy -c docker-compose.yml airflow
```

---

### 2.4 Docker Swarm Secret Immutability

> **🚨 Critical Rule:** Docker Swarm secrets are **immutable**. You cannot update a secret in place. Always create a new versioned secret (e.g. `_v2`, `_v3`) and update your stack to reference it. Remove the old one after confirming the deployment is healthy.

Recommended naming convention:

```
airflow_fernet_key_20250601     # date-versioned
airflow_fernet_key_v2           # sequence-versioned
airflow_api_secret_v2
airflow_db_conn_v2
```

---

## 3. Docker Compose Stack File

Below is a reference stack file using `_CMD` environment variables to read all infrastructure secrets from Docker Swarm secrets at container startup. Save this as `docker-compose.yml`.

```yaml
x-airflow-common: &airflow-common
  image: apache/airflow:3-latest
  environment:
    # Infrastructure secrets via _CMD (reads from /run/secrets/)
    AIRFLOW__CORE__FERNET_KEY_CMD: "cat /run/secrets/airflow_fernet_key"
    AIRFLOW__API__SECRET_KEY_CMD: "cat /run/secrets/airflow_api_secret"        # 3.x
    # AIRFLOW__WEBSERVER__SECRET_KEY_CMD: "cat /run/secrets/airflow_api_secret" # 2.x
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_CMD: "cat /run/secrets/airflow_db_conn"
    AIRFLOW__CELERY__BROKER_URL_CMD: "cat /run/secrets/airflow_broker_url"
    AIRFLOW__CELERY__RESULT_BACKEND_CMD: "cat /run/secrets/airflow_result_backend"
    # Custom secrets backend
    AIRFLOW__SECRETS__BACKEND: >-
      airflow.plugins.docker_swarm_secrets_backend.DockerSwarmSecretsBackend
    AIRFLOW__SECRETS__BACKEND_KWARGS: '{"secrets_dir": "/run/secrets"}'
    # General config
    AIRFLOW__CORE__EXECUTOR: CeleryExecutor
    AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
  secrets:
    - airflow_fernet_key
    - airflow_api_secret
    - airflow_db_conn
    - airflow_broker_url
    - airflow_result_backend
    # Application secrets for DAGs (connections and variables)
    - airflow_conn_my_postgres
    - airflow_var_s3_bucket
  volumes:
    - ./dags:/opt/airflow/dags
    - ./plugins:/opt/airflow/plugins
    - ./logs:/opt/airflow/logs

services:
  airflow-apiserver:
    <<: *airflow-common
    command: api-server
    ports:
      - "8080:8080"
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure

  airflow-scheduler:
    <<: *airflow-common
    command: scheduler
    deploy:
      replicas: 1

  airflow-worker:
    <<: *airflow-common
    command: celery worker
    deploy:
      replicas: 2

secrets:
  airflow_fernet_key:
    external: true
  airflow_api_secret:
    external: true
  airflow_db_conn:
    external: true
  airflow_broker_url:
    external: true
  airflow_result_backend:
    external: true
  airflow_conn_my_postgres:
    external: true
  airflow_var_s3_bucket:
    external: true
```

---

## 4. Custom Docker Swarm Secrets Backend

### 4.1 How It Works

There is no built-in Docker Swarm secrets backend in Airflow. However, since Docker Swarm mounts secrets as plain files at `/run/secrets/<secret_name>`, it is straightforward to build one by subclassing `BaseSecretsBackend`.

The custom backend enables DAGs to retrieve Airflow Connections, Variables, and config values from Docker secrets at task runtime — without hardcoding them in the metadata database.

| Secret Type | File Naming Convention   | Example                        |
|-------------|--------------------------|--------------------------------|
| Connection  | `airflow_conn_<conn_id>` | `airflow_conn_my_postgres`     |
| Variable    | `airflow_var_<key>`      | `airflow_var_s3_bucket`        |
| Config      | `airflow_config_<key>`   | `airflow_config_smtp_password` |

---

### 4.2 Backend Implementation

Save this file as `plugins/docker_swarm_secrets_backend.py` in your Airflow home directory. Airflow automatically discovers Python files placed in the `plugins/` directory.

```python
# plugins/docker_swarm_secrets_backend.py
from __future__ import annotations

import logging
import os
from airflow.secrets import BaseSecretsBackend

log = logging.getLogger(__name__)


class DockerSwarmSecretsBackend(BaseSecretsBackend):
    """
    Reads Airflow connections, variables, and config from
    Docker Swarm secrets mounted at /run/secrets/.

    Naming conventions (all lowercase, underscores):
      Connections : /run/secrets/airflow_conn_<conn_id>
      Variables   : /run/secrets/airflow_var_<key>
      Config      : /run/secrets/airflow_config_<key>

    File content for connections must be a valid Airflow
    Connection URI string, e.g.:
      postgresql://user:password@host:5432/dbname

    Configuration:
      [secrets]
      backend = airflow.plugins.docker_swarm_secrets_backend
               .DockerSwarmSecretsBackend
      backend_kwargs = {"secrets_dir": "/run/secrets",
                        "conn_prefix": "airflow_conn_",
                        "var_prefix": "airflow_var_",
                        "config_prefix": "airflow_config_"}
    """

    def __init__(
        self,
        secrets_dir: str = "/run/secrets",
        conn_prefix: str = "airflow_conn_",
        var_prefix: str = "airflow_var_",
        config_prefix: str = "airflow_config_",
    ):
        self.secrets_dir = secrets_dir
        self.conn_prefix = conn_prefix
        self.var_prefix = var_prefix
        self.config_prefix = config_prefix
        super().__init__()

    def _read_secret(self, filename: str) -> str | None:
        """Read and return a secret file, stripping trailing whitespace."""
        path = os.path.join(self.secrets_dir, filename)
        try:
            with open(path) as fh:
                value = fh.read().strip()
                if not value:
                    log.warning(
                        "DockerSwarmSecretsBackend: secret file %s is empty",
                        path,
                    )
                    return None
                return value
        except FileNotFoundError:
            return None
        except PermissionError:
            log.error(
                "DockerSwarmSecretsBackend: permission denied reading %s",
                path,
            )
            return None

    def get_conn_value(self, conn_id: str) -> str | None:
        """
        Return a connection URI string for the given conn_id.
        Airflow will parse the URI into a Connection object.
        """
        filename = f"{self.conn_prefix}{conn_id.lower()}"
        return self._read_secret(filename)

    def get_variable(self, key: str) -> str | None:
        """Return the value of an Airflow Variable."""
        filename = f"{self.var_prefix}{key.lower()}"
        return self._read_secret(filename)

    def get_config(self, key: str) -> str | None:
        """
        Return an Airflow config value.
        Note: only config keys in the _CMD allowlist are fully supported.
        """
        filename = f"{self.config_prefix}{key.lower()}"
        return self._read_secret(filename)
```

---

### 4.3 Registering the Backend

Set these environment variables in your stack (or in `airflow.cfg`):

```bash
AIRFLOW__SECRETS__BACKEND: >-
  airflow.plugins.docker_swarm_secrets_backend.DockerSwarmSecretsBackend

AIRFLOW__SECRETS__BACKEND_KWARGS: >-
  {"secrets_dir": "/run/secrets",
   "conn_prefix": "airflow_conn_",
   "var_prefix": "airflow_var_",
   "config_prefix": "airflow_config_"}
```

Or in `airflow.cfg`:

```ini
[secrets]
backend = airflow.plugins.docker_swarm_secrets_backend.DockerSwarmSecretsBackend
backend_kwargs = {"secrets_dir": "/run/secrets", "conn_prefix": "airflow_conn_", "var_prefix": "airflow_var_", "config_prefix": "airflow_config_"}
```

---

### 4.4 Creating Secrets for DAG Use

Create Docker secrets that match the naming convention. Connection values must be valid Airflow Connection URI strings:

```bash
# Connection (PostgreSQL example)
echo "postgresql://user:password@postgres-host:5432/mydb" \
  | docker secret create airflow_conn_my_postgres -

# Connection (S3 example)
echo "aws://AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI@/?region_name=us-east-1"
  | docker secret create airflow_conn_aws_default -

# Variable (plain string)
echo "s3://my-data-bucket/output" \
  | docker secret create airflow_var_output_path -

# Variable (JSON)
echo '{"host": "db.example.com", "port": 5432}' \
  | docker secret create airflow_var_db_config -

# Config value (e.g. SMTP password)
echo "my-smtp-password" \
  | docker secret create airflow_config_smtp_password -
```

---

### 4.5 Using Secrets in DAGs

Once the backend is registered, DAGs access connections and variables normally. No code changes are needed:

```python
from airflow.hooks.base import BaseHook
from airflow.models import Variable

# Retrieve a connection — resolved from /run/secrets/airflow_conn_my_postgres
conn = BaseHook.get_connection('my_postgres')
print(conn.host, conn.port, conn.schema)

# Retrieve a variable — resolved from /run/secrets/airflow_var_output_path
output_path = Variable.get('output_path')

# Retrieve a JSON variable
db_config = Variable.get('db_config', deserialize_json=True)
```

---

### 4.6 Lookup Precedence

When Airflow resolves a connection or variable, it follows this fixed precedence order (not configurable):

| #     | Source                 | Notes                                                    |
|-------|------------------------|----------------------------------------------------------|
| **1** | Custom Secrets Backend | `DockerSwarmSecretsBackend` — reads from `/run/secrets/` |
| 2     | Environment Variables  | `AIRFLOW_CONN_*`, `AIRFLOW_VAR_*` env vars               |
| 3     | Metastore Database     | Values set via Airflow UI, CLI, or `Variable.set()`      |

> **⚠️ Write operations:** The secrets backend is read-only by design. `Variable.set()` and `Connection.set()` always write to the metastore, even when a backend is configured. To update a Docker secret value you must create a new Docker secret and redeploy the stack.

---

## 5. Automating Key Rotation

### 5.1 Rotation Shell Script

Save this script as `scripts/rotate-airflow-keys.sh`. It handles Fernet key rotation with the transition period, and rotates the API secret key.

```bash
#!/usr/bin/env bash
# rotate-airflow-keys.sh
# Rotates Airflow Fernet key and API secret in Docker Swarm
set -euo pipefail

STACK_NAME="${STACK_NAME:-airflow}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

echo "==> [1/6] Generating new Fernet key..."
NEW_FERNET=$(python3 -c \
  'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')

echo "==> [2/6] Reading current Fernet key..."
WORKER=$(docker ps -q -f name="${STACK_NAME}_airflow-worker" | head -1)
if [ -z "$WORKER" ]; then
  echo "ERROR: No running worker container found." >&2; exit 1
fi
OLD_FERNET=$(docker exec "$WORKER" cat /run/secrets/airflow_fernet_key)

echo "==> [3/6] Creating transition and new secrets..."
echo "${NEW_FERNET},${OLD_FERNET}" \
  | docker secret create "airflow_fernet_transition_${TIMESTAMP}" -
echo "${NEW_FERNET}" \
  | docker secret create "airflow_fernet_key_${TIMESTAMP}" -

NEW_API_SECRET=$(openssl rand -hex 32)
echo "${NEW_API_SECRET}" \
  | docker secret create "airflow_api_secret_${TIMESTAMP}" -

echo "==> [4/6] Deploying with transition key (old+new for Fernet)..."
FERNET_SECRET="airflow_fernet_transition_${TIMESTAMP}" \
API_SECRET="airflow_api_secret_${TIMESTAMP}" \
  docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"

echo "    Waiting 45s for services to stabilize..."
sleep 45

echo "==> [5/6] Re-encrypting DB credentials with new Fernet key..."
WORKER=$(docker ps -q -f name="${STACK_NAME}_airflow-worker" | head -1)
docker exec "$WORKER" airflow rotate-fernet-key

echo "==> [6/6] Deploying with new key only (removing old)..."
FERNET_SECRET="airflow_fernet_key_${TIMESTAMP}" \
API_SECRET="airflow_api_secret_${TIMESTAMP}" \
  docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"

echo ""
echo "✅ Rotation complete. Verify your stack, then remove old secrets:"
echo "   docker secret rm airflow_fernet_key  (previous version)"
echo "   docker secret rm airflow_fernet_transition_${TIMESTAMP}"
```

---

### 5.2 CI/CD Scheduled Pipeline (GitHub Actions)

Schedule automatic monthly rotation using GitHub Actions with a self-hosted runner that has Docker Swarm access:

```yaml
# .github/workflows/rotate-airflow-keys.yml
name: Rotate Airflow Keys

on:
  schedule:
    - cron: '0 2 1 * *'   # Monthly, 1st of month at 02:00 UTC
  workflow_dispatch:       # Allow manual trigger

jobs:
  rotate:
    name: Rotate Airflow secrets
    runs-on: self-hosted   # Must have Docker Swarm manager access
    environment: production

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Verify Docker Swarm access
        run: docker node ls

      - name: Run rotation script
        env:
          STACK_NAME: airflow
          COMPOSE_FILE: ./docker/docker-compose.yml
        run: |
          chmod +x scripts/rotate-airflow-keys.sh
          ./scripts/rotate-airflow-keys.sh

      - name: Health check
        run: |
          sleep 30
          curl -f http://localhost:8080/api/v2/version || exit 1

      - name: Notify on failure
        if: failure()
        run: |
          echo "Key rotation failed! Manual intervention required."
          # Add your alerting here: Slack, PagerDuty, email, etc.
```

---

### 5.3 Application Secret Rotation (DAG Connections)

For rotating application secrets (connections, variables stored as Docker secrets), no Fernet re-encryption is needed since the values live in Docker secrets, not the metadata DB:

```bash
#!/usr/bin/env bash
# rotate-app-secret.sh <secret_name> <new_value>
# Example: ./rotate-app-secret.sh airflow_conn_my_postgres 'postgresql://...'
set -euo pipefail

SECRET_NAME="$1"
NEW_VALUE="$2"
STACK_NAME="${STACK_NAME:-airflow}"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
NEW_SECRET_NAME="${SECRET_NAME}_${TIMESTAMP}"

echo "Creating new secret: $NEW_SECRET_NAME"
echo "$NEW_VALUE" | docker secret create "$NEW_SECRET_NAME" -

echo "Update your docker-compose.yml to reference: $NEW_SECRET_NAME"
echo "Then run: docker stack deploy -c docker-compose.yml $STACK_NAME"
echo "After confirming healthy, remove: docker secret rm $SECRET_NAME"
```

---

## 6. Important Caveats & Best Practices

### 6.1 Worker Secret Caching

> **⚠️ Warning:** Long-lived Celery workers can cache secrets in memory. If you rotate a Docker secret, workers must be restarted to pick up the new value. `docker stack deploy` triggers a rolling restart automatically.

To force an immediate worker restart without redeploying the full stack:

```bash
docker service update --force airflow_airflow-worker
# Or target the api-server if the secret is needed there:
# docker service update --force airflow_airflow-apiserver
```

---

### 6.2 Secret Scope Per Service

Each Docker service must explicitly list every secret it needs to access. A secret mounted on the webserver is **not** automatically available to workers. Be deliberate:

| Secret               | API server | Scheduler | Worker | Triggerer | Notes                     |
|----------------------|------------|-----------|--------|-----------|---------------------------|
| `airflow_fernet_key` | ✅          | ✅         | ✅      | ✅         | All components decrypt DB |
| `airflow_api_secret` | ✅          | ✅         | ❌      | ❌         | API server only           |
| `airflow_db_conn`    | ✅          | ✅         | ✅      | ✅         | All need metadata DB      |
| `airflow_broker_url` | ❌          | ✅         | ✅      | ✅         | Celery components         |
| `airflow_conn_*`     | ❌          | ❌         | ✅      | ✅         | Task execution only       |
| `airflow_var_*`      | ❌          | ❌         | ✅      | ✅         | Task execution only       |

---

### 6.3 Security Best Practices

- Never store secret values in environment variables directly — use `_CMD` to read from `/run/secrets/`.
- Use versioned secret names (`_v2`, `_20250601`) — never try to update a secret in place.
- Remove old secrets promptly after confirming the new deployment is healthy.
- Restrict which services receive which secrets — apply least-privilege per service.
- Run `rotate-fernet-key` before removing the old Fernet key from the comma-separated list.
- Test rotation in a staging stack before running in production.
- Monitor the `/health` endpoint after every rotation to confirm a healthy state.
- Audit Docker secret access using `docker secret inspect` and Swarm audit logs.

---

### 6.4 Limitations of the Custom Backend

- **Read-only:** `Variable.set()` always writes to the Airflow metastore, not to Docker secrets.
- **No automatic discovery:** every secret used by DAGs must be explicitly listed under `secrets:` in the stack file.
- **No TTL or expiry:** Docker secrets have no built-in expiration. You must manage rotation externally.
- **No audit log:** Docker secrets do not natively log access. Consider a dedicated secret manager (Vault, AWS Secrets Manager) for compliance requirements.

---

## 7. Quick Reference Checklists

### 7.1 Fernet Key Rotation Checklist

1. Generate a new Fernet key with the `cryptography` library.
2. Create a transition Docker secret containing `new_key,old_key`.
3. Update the stack to reference the transition secret.
4. Run `docker stack deploy` and wait for services to stabilize.
5. Execute `airflow rotate-fernet-key` on any worker container.
6. Create a clean Docker secret with only the new key.
7. Update the stack to reference the clean new secret.
8. Verify the webserver `/health` endpoint responds correctly.
9. Remove the old secret and transition secret.

### 7.2 Application Secret Rotation Checklist

1. Generate or obtain the new secret value.
2. Create a new versioned Docker secret (e.g. `airflow_conn_x_v2`).
3. Update `docker-compose.yml` to reference the new secret name.
4. Run `docker stack deploy`.
5. Verify affected DAGs and tasks are operating correctly.
6. Remove the old Docker secret.

### 7.3 Full Environment Setup Checklist

1. Generate Fernet key and create `airflow_fernet_key` Docker secret.
2. Generate API/webserver secret and create `airflow_api_secret`.
3. Create `airflow_db_conn` with the full SQLAlchemy connection URI.
4. Create `airflow_broker_url` and `airflow_result_backend` for Celery.
5. Place `docker_swarm_secrets_backend.py` in the `plugins/` directory.
6. Set `AIRFLOW__SECRETS__BACKEND` and `BACKEND_KWARGS` in the stack.
7. Add `_CMD` environment variables for all infrastructure secrets.
8. List all required secrets under `secrets:` for each service.
9. Deploy the stack and verify all services start healthy.
10. Create application connection and variable secrets as needed.
11. Test DAG execution and verify secret resolution works correctly.
12. Schedule automated rotation via CI/CD or cron.