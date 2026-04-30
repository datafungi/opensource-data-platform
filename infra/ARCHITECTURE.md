# Data Platform Architecture

Self-hosted, 100% open-source data platform deployable on generic Linux VMs or
self-hosted Kubernetes. No cloud-managed services required.

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Stack Overview](#2-stack-overview)
3. [Local Development](#3-local-development)
4. [Docker Swarm Production](#4-docker-swarm-production)
5. [Kubernetes Self-Hosted](#5-kubernetes-self-hosted)
6. [Data Flow Architecture](#6-data-flow-architecture)
7. [Data Contract Layer](#7-data-contract-layer)
8. [Secrets Management](#8-secrets-management)
9. [Storage Strategy](#9-storage-strategy)
10. [Observability](#10-observability)
11. [Operational Runbooks](#11-operational-runbooks)

---

## 1. Design Philosophy

**OSS-first.** Every tool is open-source with a permissive license (Apache 2.0, BSD,
PostgreSQL). No AGPL, no proprietary managed services.

**Self-hosted, cloud-agnostic.** The platform runs on any Linux VMs — bare-metal,
private cloud, or any public cloud provider — using the same compose files and Ansible
playbooks regardless of where the machines live.

**Contract-driven quality.** Data quality is enforced through the Open Data Contract
Standard (ODCS). Every dataset has a contract; every contract has SodaCL checks that
run daily. A red Airflow task is the signal that the producer must investigate.

**Secrets never in code.** All credentials are stored in HashiCorp Vault and injected
at runtime. No secrets in environment files, Docker configs, or git history.

**Observability from day one.** Prometheus and Grafana are first-class services, not
afterthoughts. Every service exports metrics; alerting is configured from deployment.

---

## 2. Stack Overview

| Function        | Tool                                | Version |
|-----------------|-------------------------------------|---------|
| Orchestration   | Apache Airflow                      | 3.2     |
| Relational DB   | PostgreSQL                          | 17      |
| Broker          | Redis                               | 8       |
| Analytics DB    | ClickHouse                          | 25.4    |
| Object storage  | SeaweedFS                           | 4.21    |
| Secrets         | HashiCorp Vault                     | 1.19.0  |
| SQL transforms  | dbt-core + dbt-clickhouse + cosmos  | 1.8     |
| Federated SQL   | Trino                               | 480     |
| Batch compute   | Apache Spark                        | 4.1.1   |
| Stream ingest   | Apache Kafka (KRaft)                | 4.0     |
| Stream compute  | Apache Flink                        | 2.2.0   |
| Table format    | Apache Iceberg                      | 1.10.1  |
| Iceberg catalog | Apache Polaris                      | latest  |
| Data quality    | Soda Core                           | 3.4     |
| Data lineage    | Marquez + OpenLineage               | latest  |
| Metrics         | Prometheus + Grafana                | latest  |
| Distributed FS  | GlusterFS (Swarm only)              | latest  |

### When to use Docker Swarm vs Kubernetes

| Dimension              | Docker Swarm     | Kubernetes   |
|------------------------|------------------|--------------|
| DAG count              | ≤ 100            | 100+         |
| Concurrent tasks       | ≤ 30             | 50+          |
| Downtime tolerance     | Hours acceptable | < 30 minutes |
| Team size              | 1–3 engineers    | 3+ engineers |
| Setup time             | Hours            | Days         |
| Operational complexity | Low              | Medium–High  |

---

## 3. Local Development

All components run as Docker Compose services sharing the `data-platform-dev` network.

### Compose files

| File                                  | Services                                  |
|---------------------------------------|-------------------------------------------|
| `infra/dev/compose/airflow.lite.yaml` | Airflow (LocalExecutor), PostgreSQL       |
| `infra/dev/compose/clickhouse.yaml`   | ClickHouse 25.4                           |
| `infra/dev/compose/seaweedfs.yaml`    | SeaweedFS (master + volume + filer + S3)  |
| `infra/dev/compose/vault.yaml`        | HashiCorp Vault 1.19.0 (dev mode)         |
| `infra/dev/compose/trino.yaml`        | Trino 480 (single-node coordinator)       |
| `infra/dev/compose/spark.yaml`        | Spark 4.1.1 master + 1 worker             |
| `infra/dev/compose/kafka.yaml`        | Kafka 4.0 (KRaft, single-node)            |
| `infra/dev/compose/flink.yaml`        | Flink 2.2.0 JobManager + TaskManager      |

### Ports

| Service            | Port | Notes                    |
|--------------------|------|--------------------------|
| Airflow UI         | 8080 |                          |
| Flink Web UI       | 8082 |                          |
| Vault UI + API     | 8200 | token: `root` (dev mode) |
| SeaweedFS S3 API   | 8333 |                          |
| SeaweedFS filer UI | 8888 |                          |
| Trino UI + API     | 8085 |                          |
| Spark master UI    | 8090 |                          |
| Spark worker UI    | 8091 |                          |
| ClickHouse HTTP    | 8123 |                          |
| ClickHouse native  | 9000 |                          |
| SeaweedFS master   | 9333 |                          |
| Kafka broker       | 9092 |                          |

### Make targets

```bash
make up [component...]    # start all or specific components (kafka, flink, spark, trino…)
make down [component...]  # stop
make build                # build the local Airflow image
make vault-init           # seed Vault dev with Airflow secrets
make seaweedfs-init       # create S3 buckets (airflow-logs, backups, iceberg-warehouse)
make kafka-init           # create default Kafka topics (raw-orders, flink-output)
```

---

## 4. Docker Swarm Production

### Node layout

3 Linux VMs connected by a private network (any provider or bare-metal):

| Node  | Label                             | Stateful services                                | Other services                              |
|-------|-----------------------------------|--------------------------------------------------|---------------------------------------------|
| node1 | `stateful=true`, `nodename=node1` | PostgreSQL, Redis, Vault, SeaweedFS master+filer | Airflow Scheduler, DAG Processor, Triggerer |
| node2 | `nodename=node2`                  | SeaweedFS volume                                 | Airflow API Server, Workers, ClickHouse     |
| node3 | `nodename=node3`                  | SeaweedFS volume                                 | Trino, Prometheus, Grafana, Airflow Workers |

Shared across all nodes:
- **GlusterFS replica=3** at `/mnt/gluster` — persistent volumes for all stateful services
- **git-sync** (global) — pulls DAGs from the repository every 60 seconds
- **node-exporter** (global) — host metrics for Prometheus

### Swarm stack files

| File                        | Services deployed                                        |
|-----------------------------|----------------------------------------------------------|
| `compose/databases.yaml`    | PostgreSQL 17, Redis 8                                   |
| `compose/secrets.yaml`      | HashiCorp Vault 1.19.0                                   |
| `compose/storage.yaml`      | SeaweedFS 4.21 (master, volume servers, filer)           |
| `compose/airflow.yaml`      | Airflow API server, scheduler, workers, flower, git-sync |
| `compose/airflow-init.yaml` | One-time DB migration + admin user creation              |
| `compose/analytics.yaml`    | ClickHouse 25.4, Trino 480                               |
| `compose/streaming.yaml`    | Kafka 4.0 (KRaft), Flink 2.2.0 (1 JM + 2 TM replicas)  |
| `compose/monitor.yaml`      | Prometheus, Grafana, StatsD exporter, exporters          |

### Networking

All services communicate over a Docker overlay network (`data-platform`). Inbound access:
- Port 8080 (Airflow UI) — Tailscale subnet only
- Port 3000 (Grafana) — Tailscale subnet only
- Port 8200 (Vault) — Tailscale subnet only
- Port 8085 (Trino) — Tailscale subnet only

SSH access via Tailscale or firewall-restricted port 22. No public-facing services.

### High Availability

- **GlusterFS replica=3**: any single node can fail; reads/writes continue from
  the other two nodes. All stateful service volumes (`postgres-data`, `redis-data`,
  `vault-data`, `seaweedfs-*`) are backed by GlusterFS.
- **PostgreSQL and Redis**: single replica. GlusterFS protects against node failure
  (data survives); the services restart on a surviving node within minutes.
- **Airflow workers**: global service — automatically replaced on surviving nodes.
- **SeaweedFS**: distributed volume servers on all 3 nodes; master on node1.

### Deploy procedure

```bash
# 1. Label nodes
docker node update --label-add stateful=true --label-add nodename=node1 <node1-id>
docker node update --label-add nodename=node2 <node2-id>
docker node update --label-add nodename=node3 <node3-id>

# 2. Create GlusterFS mounts (via Ansible: ansible/deploy-databases.yml)

# 3. Deploy in dependency order
docker stack deploy -c infra/docker-stack/compose/databases.yaml data-platform
docker stack deploy -c infra/docker-stack/compose/secrets.yaml data-platform
# → run vault operator init + unseal (see docs/vault_setup.md)
docker stack deploy -c infra/docker-stack/compose/storage.yaml data-platform
docker stack deploy -c infra/docker-stack/compose/airflow-init.yaml data-platform
# → wait for airflow-init to complete
docker stack deploy -c infra/docker-stack/compose/airflow.yaml data-platform
docker stack deploy -c infra/docker-stack/compose/analytics.yaml data-platform
docker stack deploy -c infra/docker-stack/compose/streaming.yaml data-platform
docker stack deploy -c infra/docker-stack/compose/monitor.yaml data-platform
```

See `docs/vault_setup.md` and `docs/seaweedfs_setup.md` for bootstrap procedures.

---

## 5. Kubernetes Self-Hosted

Uses [helmfile](https://helmfile.readthedocs.io/) to manage all Helm releases.
Works with **k3s** (recommended) or kubeadm.

See [`../k8s-stack/README.md`](../k8s-stack/README.md) for full setup instructions.

```bash
cd infra/k8s-stack
helmfile repos   # add chart repositories
helmfile sync    # deploy all releases
```

### Releases

| Release                 | Chart                  | Namespace     |
|-------------------------|------------------------|---------------|
| `vault`                 | hashicorp/vault        | data-platform |
| `seaweedfs`             | seaweedfs/seaweedfs    | data-platform |
| `postgresql`            | bitnami/postgresql     | data-platform |
| `redis`                 | bitnami/redis          | data-platform |
| `clickhouse`            | bitnami/clickhouse     | data-platform |
| `airflow`               | apache-airflow/airflow | data-platform |
| `trino`                 | trino/trino            | data-platform |
| `kube-prometheus-stack` | prometheus-community   | monitoring    |

---

## 6. Data Flow Architecture

```
Source systems
  └── Airflow DAG (ingest)
        └── ClickHouse raw layer (orders table)
              └── dbt (via cosmos DbtDag)
                    └── stg_orders (view)
                    └── int_orders_enriched (view)
                    └── fct_orders (ReplacingMergeTree, incremental)
                          └── SodaScanOperator (quality gate — airflow-provider-soda)
                          └── ODCSOperator (contract validation — airflow-provider-odcs)
                          └── Trino (federated query → consumers)
              └── Spark job → Iceberg tables on SeaweedFS
                    └── Trino (Iceberg catalog via Polaris)

Stream path:
  Kafka (KRaft) → Flink job → ClickHouse (real-time sink)

Lineage: every Airflow task emits OpenLineage events → Marquez
```

### DAG dependency chain

```
etl_orders_dag          (ingest raw data to ClickHouse)
  └── dbt_clickhouse    (cosmos DbtDag — staging → intermediate → marts)

spark_iceberg_example   (independent — daily Iceberg table refresh)
backup_dag              (independent — nightly PG + Redis backups to SeaweedFS)
```

Quality and contract validation are triggered directly from DAGs using
`SodaScanOperator` (from `airflow-provider-soda`) and `ODCSOperator`
(from `airflow-provider-odcs`) — both located in `airflow/dags/plugins/`.

---

## 7. Data Contract Layer

Data contracts follow the [Open Data Contract Standard (ODCS)](https://bitol-io.github.io/open-data-contract-standard/) v3.1.0.

Each contract (`data-contracts/*_contract.yaml`) defines:
- **Schema**: column names, types, nullability, primary keys
- **Quality**: SodaCL checks embedded inline (completeness, uniqueness, validity, freshness)
- **Terms**: usage rights, limitations
- **Service levels**: availability and freshness SLAs

### Custom Airflow providers

Quality and contract tooling is packaged as installable Airflow providers under
`airflow/dags/plugins/`:

| Provider package         | Operator          | Purpose                                |
|--------------------------|-------------------|----------------------------------------|
| `airflow-provider-odcs`  | `ODCSOperator`    | Reads ODCS contract, runs SodaCL check |
| `airflow-provider-soda`  | `SodaScanOperator`| Runs a Soda scan against a data source |

Both are currently placeholders (`NotImplementedError`); implement by installing the
packages from their `pyproject.toml` and wiring them into DAGs.

### Validation pipeline (target)

```
ODCSOperator (airflow-provider-odcs)
  1. Reads ODCS v3.1.0 contract YAML
  2. Extracts quality.specification block
  3. Writes to a temp SodaCL file
  4. Runs: soda scan -d <data_source> -c soda/configuration.yml <checks_file>
  5. Raises AirflowException on any check failure
  6. Emits OpenLineage dataset event → Marquez
```

---

## 8. Secrets Management

All credentials are stored in **HashiCorp Vault** (KV v2 secrets engine).

### Vault path layout

```
secret/airflow/config/fernet-key
secret/airflow/config/sql-alchemy-conn
secret/airflow/config/broker-url
secret/airflow/config/result-backend
secret/airflow/connections/<conn_id>
secret/airflow/variables/<key>
```

### How it works in Docker Swarm

1. Vault token stored as Docker secret `vault_airflow_token`
2. `airflow-entrypoint.sh` reads it: `export VAULT_TOKEN=$(cat /run/secrets/vault_airflow_token)`
3. Airflow `VaultBackend` uses the token to resolve connections, variables, and config at runtime
4. Infrastructure secrets (`_SECRET` env vars) are resolved once at container startup
5. DAG connections and variables are resolved on demand — no restart needed after rotation

### How it works in Kubernetes

1. Vault token stored as K8s Secret `vault-airflow-token`
2. Injected into Airflow pods via `extraEnvFrom.secretRef`
3. Same `VaultBackend` configuration as Swarm

See `docs/airflow_secrets_management.md` for the full bootstrap and rotation procedures.

---

## 9. Storage Strategy

### Object storage — SeaweedFS

SeaweedFS (Apache 2.0) provides S3-compatible storage for:

| Bucket              | Contents                              |
|---------------------|---------------------------------------|
| `airflow-logs`      | Airflow task logs (remote logging)    |
| `backups`           | Nightly pg_dump + Redis RDB snapshots |
| `iceberg-warehouse` | Iceberg table data files (Parquet)    |

In Docker Swarm: distributed mode (master + volume server per node + filer on node1).
In dev: single-node all-in-one compose service.

### Distributed filesystem — GlusterFS (Swarm only)

GlusterFS replica=3 at `/mnt/gluster` provides HA for service volumes:

| Volume             | Path                            | Service                   |
|--------------------|---------------------------------|---------------------------|
| `postgres-data`    | `/mnt/gluster/postgres-data`    | PostgreSQL data dir       |
| `redis-data`       | `/mnt/gluster/redis-data`       | Redis AOF + RDB           |
| `vault-data`       | `/mnt/gluster/vault-data`       | Vault file storage        |
| `seaweedfs-master` | `/mnt/gluster/seaweedfs-master` | SeaweedFS master metadata |
| `seaweedfs-volume` | `/mnt/gluster/seaweedfs-volume` | SeaweedFS volume data     |
| `clickhouse-data`  | `/mnt/gluster/clickhouse-data`  | ClickHouse table data     |
| `prometheus-data`  | `/mnt/gluster/prometheus-data`  | Prometheus TSDB           |
| `grafana-data`     | `/mnt/gluster/grafana-data`     | Grafana dashboards        |

**PostgreSQL tuning on GlusterFS** (required to preserve fsync semantics):
```bash
gluster volume set pg-data performance.cache-size 0
gluster volume set pg-data performance.write-behind off
gluster volume set pg-data performance.read-ahead off
gluster volume set pg-data storage.batch-fsync-delay-usec 0
```

---

## 10. Observability

### Prometheus scrape targets

| Exporter          | Target                      | Metrics                             |
|-------------------|-----------------------------|-------------------------------------|
| statsd-exporter   | `statsd-exporter:9102`      | Airflow DAG/task/pool metrics       |
| postgres-exporter | `postgres-exporter:9187`    | PostgreSQL connection, query stats  |
| redis-exporter    | `redis-exporter:9121`       | Redis memory, keyspace stats        |
| node-exporter     | `<node-ip>:9100`            | CPU, memory, disk, network per node |
| Vault native      | `vault:8200/v1/sys/metrics` | Vault request latency, token counts |
| SeaweedFS         | `seaweedfs-master:9333`     | Object counts, volume capacity      |

### Key Grafana dashboards

| Dashboard          | Grafana ID |
|--------------------|------------|
| Node Exporter Full | 1860       |
| PostgreSQL         | 9628       |
| Redis              | 763        |
| Airflow            | 20994      |

### Critical alerts

| Alert                      | Condition                                    | Severity |
|----------------------------|----------------------------------------------|----------|
| Scheduler not heartbeating | `airflow_scheduler_heartbeat < 1` for 5m     | critical |
| Queue depth high           | `airflow_executor_queued_tasks > 50` for 10m | warning  |
| Disk usage high            | Filesystem > 80% full                        | warning  |
| Vault sealed               | Vault health check fails                     | critical |

---

## 11. Operational Runbooks

### Bootstrap a new Swarm cluster

1. Provision 3 Linux VMs with SSH access
2. Install Docker Engine and Docker Swarm: `docker swarm init` on node1, `docker swarm join` on node2/3
3. Install GlusterFS and configure the replicated volume (see `ansible/deploy-databases.yml`)
4. Label nodes: `docker node update --label-add ...`
5. Deploy stacks in order (see Section 4)
6. Bootstrap Vault: `vault operator init` → unseal → write secrets (see `docs/vault_setup.md`)
7. Create SeaweedFS buckets (see `docs/seaweedfs_setup.md`)
8. Create Airflow admin user via `airflow-init` stack

### Update a running service

```bash
# Push a new image
docker service update --image <new-image> data-platform_airflow-apiserver

# Update a compose file (rolling update)
docker stack deploy -c infra/docker-stack/compose/airflow.yaml data-platform
```

### Vault unseal after restart

```bash
docker exec -it $(docker ps -q -f name=data-platform_vault) vault operator unseal
# Run 3 times with different keys
```

### Node failure recovery

**Single worker node failure** (node2 or node3):
- Swarm automatically reschedules global services (node-exporter, git-sync, SeaweedFS volume)
- Stateful services (PostgreSQL, Redis, Vault) are pinned to node1 — unaffected
- Airflow workers on the failed node are re-scheduled on remaining nodes automatically
- RTO: ~1–2 minutes

**Node1 failure (stateful node)**:
- PostgreSQL, Redis, Vault, SeaweedFS master/filer become unavailable
- GlusterFS data is intact on node2 and node3
- Manually update Swarm placement constraints to float services to node2:
  ```bash
  docker service update --constraint-rm 'node.labels.nodename==node1' \
    --constraint-add 'node.labels.nodename==node2' data-platform_postgres
  ```
- RTO: 5–10 minutes (manual intervention required)

### Rotate a secret

```bash
# Update value in Vault
vault kv put secret/airflow/connections/my_postgres value="postgresql://user:newpass@host:5432/db"

# DAG connections: no restart needed — next task access picks up the new value.
# Infrastructure secrets (_SECRET vars): restart the affected service.
docker service update --force data-platform_airflow-scheduler
```
