# Monitoring Deployment

### Docker Swarm — via Ansible from the local machine

|                    |                                                    |
|--------------------|----------------------------------------------------|
| **Scope**          | Prometheus, Grafana, and exporters on Docker Swarm |
| **Applies to**     | `deploy-monitor.yml`                               |
| **Classification** | Internal / Operational                             |

---

## Prerequisites

- **Databases stack is running.** `deploy-databases.yml` must have completed
  successfully — the `data-platform` overlay network must exist.
- **Node labels set.** `deploy-databases.yml` applies `nodename=node1/2/3` to
  all three Swarm nodes. The monitoring stack uses these labels to pin all
  monitoring services to node3.
- **`az login` active** on this machine with access to the Key Vault.
- **Ansible collection installed:**

```bash
cd infra/docker-stack/ansible
ansible-galaxy collection install -r requirements.yml
```

---

## Running the playbook

```bash
cd infra/docker-stack/ansible
ansible-playbook deploy-monitor.yml
```

The playbook runs two plays:

**Play 1 — localhost:**
1. Checks whether `grafana-admin-password` exists in Key Vault; generates and
   stores a random password if not.
2. Reads `grafana-admin-password` and `postgres-airflow-password` from Key
   Vault to assemble the postgres-exporter DSN.

**Play 2 — node-1 (swarm_primary):**
1. Installs `python3-docker` via apt (required by `community.docker` modules).
2. Creates `/mnt/gluster/prometheus-data` (owner `65534`) and
   `/mnt/gluster/grafana-data` (owner `472`) on the GlusterFS volume.
   GlusterFS replicates these to all nodes so the bind mounts on node3 are
   satisfied at service start. This is idempotent — existing directories are
   left unchanged.
3. Creates the `grafana_admin_password` Docker secret.
4. Creates the `postgres_exporter_dsn` Docker secret with the full DSN string
   (`postgresql://airflow:<pw>@postgres:5432/airflow?sslmode=disable`).
5. Creates the `prometheus_config` Docker config from
   `compose/prometheus/prometheus.yml`.
6. Creates the `statsd_mapping` Docker config from
   `compose/statsd/statsd_mapping.yml`.
7. Copies `compose/monitor.yaml` to `/opt/stacks/monitor.yaml` on node-1.
8. Runs `docker stack deploy`.

---

## Services and placement

| Service             | Replicas             | Placement | Port                           |
|---------------------|----------------------|-----------|--------------------------------|
| `prometheus`        | 1                    | node3     | 9090                           |
| `grafana`           | 1                    | node3     | 3000                           |
| `statsd-exporter`   | 1                    | node3     | 9102 (HTTP), 9125/udp (StatsD) |
| `postgres-exporter` | 1                    | node3     | 9187                           |
| `redis-exporter`    | 1                    | node3     | 9121                           |
| `node-exporter`     | global (all 3 nodes) | host-mode | 9100                           |

All single-replica services are pinned to node3 via `node.labels.nodename == node3`.
node3 also runs an Airflow worker — combined resource usage stays well within
the 4 vCPU / 16 GB available.

---

## Node-exporter scraping

`node-exporter` runs as a global Swarm service (one task per node) and
publishes port 9100 in **host mode** — binding directly on each VM's NIC rather
than going through the Swarm ingress VIP. Without host mode, the VIP would
round-robin across all three tasks, so Prometheus could never get a stable
per-node metric stream.

Prometheus scrapes all three nodes by private IP, with a `node` label to
distinguish them in Grafana:

```yaml
- job_name: node
  static_configs:
    - targets: ["10.54.1.10:9100"]
      labels: { node: node-1 }
    - targets: ["10.54.1.11:9100"]
      labels: { node: node-2 }
    - targets: ["10.54.1.12:9100"]
      labels: { node: node-3 }
```

---

## Secrets and configs

| Docker object            | Type   | Source                                                      |
|--------------------------|--------|-------------------------------------------------------------|
| `grafana_admin_password` | Secret | Key Vault `grafana-admin-password` — generated on first run |
| `postgres_exporter_dsn`  | Secret | Assembled from Key Vault `postgres-airflow-password`        |
| `prometheus_config`      | Config | Content of `compose/prometheus/prometheus.yml`              |
| `statsd_mapping`         | Config | Content of `compose/statsd/statsd_mapping.yml`              |

Docker secrets and configs are immutable once created. To rotate the Grafana
password:

```bash
# 1. Update Key Vault
az keyvault secret set --vault-name <vault> --name grafana-admin-password --value <new-pw>

# 2. Delete the Swarm secret and re-run
docker secret rm grafana_admin_password
ansible-playbook deploy-monitor.yml
```

To update `prometheus.yml` (e.g. add a new scrape target):

```bash
# On node-1
docker config rm prometheus_config
ansible-playbook deploy-monitor.yml
```

---

## Accessing the dashboards

Both services are accessible from any device on the tailnet:

| Dashboard  | URL                      | Credentials                                |
|------------|--------------------------|--------------------------------------------|
| Grafana    | `http://10.54.1.10:3000` | admin / `grafana-admin-password` KV secret |
| Prometheus | `http://10.54.1.10:9090` | —                                          |

Ports are published via the Swarm routing mesh and are reachable on any node
IP, regardless of which node runs the container.

---

## Setting up Grafana dashboards

### 1. Add the Prometheus data source

1. Open Grafana at `http://10.54.1.10:3000` and sign in.
2. Navigate to **Connections → Data sources → Add new data source**.
3. Select **Prometheus**.
4. Set **URL** to `http://prometheus:9090` — Grafana and Prometheus share the
   `data-platform` overlay network, so the service name resolves internally.
5. Leave everything else at defaults and click **Save & test**. You should see
   "Successfully queried the Prometheus API."

### 2. Import community dashboards

Navigate to **Dashboards → New → Import**, enter the dashboard ID, click
**Load**, select the Prometheus data source created above, then click **Import**.

| Dashboard              | ID    | Data source job | What it shows                                      |
|------------------------|-------|-----------------|----------------------------------------------------|
| Node Exporter Full     | 1860  | `node`          | Per-node CPU, memory, disk I/O, network throughput |
| PostgreSQL Database    | 9628  | `postgres`      | Connections, queries/s, cache hit ratio, locks     |
| Redis Dashboard        | 763   | `redis`         | Memory, commands/s, hit rate, connected clients    |
| Airflow cluster        | 20994 | `statsd`        | Scheduler heartbeat, pool slots, executor slots    |
| Airflow DAG            | 20789 | `statsd`        | DAG run durations, task state breakdown per DAG    |

### 3. Node Exporter Full — configure the node variable

After import, open the **Node Exporter Full** dashboard and click
**Dashboard settings → Variables → node**. Confirm the label filter is:

```
label_values(node_uname_info{job="node"}, node)
```

This populates the **node** drop-down from the `node` label you set in
`prometheus.yml` (`node-1`, `node-2`, `node-3`). Select individual nodes or
**All** to compare them side-by-side.

### 4. Airflow dashboard — re-deploy statsd-exporter first

Airflow's metrics include variable parts (DAG ID, task ID, state) that must be
extracted into Prometheus **labels** to be queryable. Without a mapping config,
statsd-exporter bakes them into the metric name
(`airflow_ti_start_my_dag_my_task`) — impossible for dashboards to filter on.

`compose/statsd/statsd_mapping.yml` configures the extraction. The
`deploy-monitor.yml` playbook loads it as a Docker config at deploy time.

**Re-deploy to apply the mapping config:**

```bash
# Remove the old config (Docker configs are immutable once created)
# On node-1:
docker config rm statsd_mapping 2>/dev/null || true

# From your local machine:
cd infra/docker-stack/ansible
ansible-playbook deploy-monitor.yml
```

**Verify metrics are flowing with proper labels:**

Open `http://10.54.1.10:9090` and run:

```promql
{job="statsd"}
```

After the scheduler sends at least one heartbeat (~30 s), you should see
labeled metrics such as:

```
airflow_ti_start_total{dag_id="my_dag", task_id="my_task"}
airflow_dagrun_duration_success_seconds_count{dag_id="my_dag"}
airflow_pool_open_slots{pool_name="default_pool"}
airflow_executor_open_slots
airflow_scheduler_heartbeat_total
```

**Import the Airflow dashboards:**

Import both IDs in the Grafana dialog:

- **20994** — Airflow cluster dashboard (scheduler heartbeat, pool slots, executor slots)
- **20789** — Airflow DAG dashboard (run durations, task state breakdown per DAG)

If individual panels show "No data", click **Edit** on the panel and verify the
metric name matches what appears in the Prometheus Explore tab — minor Airflow
version differences can shift a metric name.

### 5. Recommended alert rules

Once data is flowing, add these alert rules under **Alerting → Alert rules**:

| Alert                      | Query                                                                                                  | Threshold   |
|----------------------------|--------------------------------------------------------------------------------------------------------|-------------|
| Node memory critical       | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`                              | > 90%       |
| Node disk filling          | `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100` | > 80%       |
| Postgres connection spike  | `pg_stat_activity_count`                                                                               | > 80        |
| Scheduler not heartbeating | `increase(airflow_scheduler_heartbeat_total[5m])`                                                      | == 0 for 5m |

Set the **Contact point** to an email or Slack webhook under
**Alerting → Contact points** before saving rules.
