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
cd infra/docker-stack/providers/azure/ansible
ansible-galaxy collection install -r requirements.yml
```

---

## Running the playbook

```bash
cd infra/docker-stack/providers/azure/ansible
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
6. Copies `compose/monitor.yaml` to `/opt/stacks/monitor.yaml` on node-1.
7. Runs `docker stack deploy`.

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
