# Data Platform Infrastructure Architecture

> **Scope:** Azure, GCP, and AWS. Cloud-specific pricing figures in this document reference **Azure Southeast Asia** unless stated otherwise. GCP and AWS equivalents are noted where they diverge meaningfully.
>
**Status:** Design phase — pre-implementation reference. All cost figures are estimates; verify against live pricing calculators before procurement.
---
> 

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [Stack Selection Guide](#2-stack-selection-guide)
3. [Docker Stack Architecture](#3-docker-stack-architecture)
4. [Kubernetes Stack Architecture](#4-kubernetes-stack-architecture)
5. [Cross-Stack Comparison](#5-cross-stack-comparison)
6. [Migration Path: Docker → Kubernetes](#6-migration-path-docker--kubernetes)
7. [Cost Optimization](#7-cost-optimization)
8. [Failover Runbooks](#8-failover-runbooks)

---

## 1. Design Philosophy

This platform is designed around two deployment stacks that share the same service roster but apply fundamentally different reliability and cost trade-offs. Both stacks are governed by four non-negotiable principles:

### Scalability
Neither stack should require a full re-architecture to handle increased data volumes or additional DAGs. Scaling mechanisms differ — vertical and manual on the Docker stack, horizontal and automated on the Kubernetes stack — but both must support growth without degradation.

### Resilience & Fault Tolerance
Failure is assumed, not exceptional. The two stacks differ in *recovery time objective* (RTO), not in *whether* they handle failures. The Docker stack targets RTO in minutes; the Kubernetes stack targets zero-downtime or sub-second automatic recovery.

### Security
Public exposure is minimized to exactly what end users require: the Airflow web UI and Grafana. All inter-service communication is private. Secrets never appear in environment files committed to source control or in container environment variables in plain text.

### Observability & Monitoring
Both stacks ship Prometheus and Grafana as first-class services, not afterthoughts. Every service exports metrics. Alerting is configured from day one.

---

## 2. Stack Selection Guide

### Recommended Workloads

| Dimension                     | Docker Stack                           | Kubernetes Stack                               |
|-------------------------------|----------------------------------------|------------------------------------------------|
| **DAG count**                 | Up to ~100 DAGs                        | 100+ DAGs                                      |
| **Concurrent tasks**          | Up to ~30 concurrent tasks             | 50+ concurrent tasks                           |
| **Data velocity**             | Batch + micro-batch (≥1 min intervals) | Near-real-time: sub-hourly, streaming triggers |
| **Data volume processed/day** | Up to ~100 GB/day                      | 100 GB/day and above                           |
| **Downtime tolerance**        | 2–8 hours acceptable                   | <30 minutes; ideally zero                      |
| **Team size**                 | 1–5 data engineers                     | 5+ engineers, multiple teams                   |
| **Infrastructure ownership**  | Single team manages everything         | Platform team + consumer teams                 |
| **Budget (Azure, monthly)**   | ~$330–490/month                        | ~$490–680/month (minimum node count)           |
| **Setup time**                | Hours to days                          | Days to weeks                                  |

### Adoption Decision Tree

```
Is downtime of 2–8 hours acceptable?
├── No  → Kubernetes Stack
└── Yes
    ├── Do you have >100 concurrent DAGs or >30 concurrent tasks?
    │   ├── Yes → Kubernetes Stack
    │   └── No
    │       ├── Do you have a dedicated platform/infra team?
    │       │   ├── Yes → Kubernetes Stack (team can manage the complexity)
    │       │   └── No  → Docker Stack
    │       └── Is monthly budget constrained to <$500?
    │           ├── Yes → Docker Stack
    │           └── No  → Either (preference-driven)
```

### Migration Triggers (Docker → Kubernetes)

Migrate when **two or more** of the following are consistently true:

- Celery worker queue backlog exceeds 30 queued tasks for >15 minutes
- Airflow scheduler heartbeat lag exceeds 5 seconds
- DAG parsing time exceeds 30 seconds (indicator of >80–100 complex DAGs)
- A single downtime incident lasts >4 hours and impacts a business deadline
- Team grows beyond 5 engineers writing DAGs concurrently
- Daily processed data volume approaches 100 GB
- A second business unit or product team needs isolated Airflow resources

---

## 3. Docker Stack Architecture

### 3.1 Logical Design Principles

**Self-contained deployment.** All services run as Docker containers on a fixed 3-node cluster. No cloud-managed databases or caches — every service lives inside the cluster. This eliminates managed service costs and network latency between services.

**Swarm Mode for multi-node coordination.** Docker Swarm Mode (built into Docker Engine) is used instead of a single-host Compose deployment. This gives the cluster real HA for stateless services, a rolling update mechanism, and distributed load balancing via the routing mesh — at significantly lower operational cost than Kubernetes.

**GlusterFS for distributed persistent storage.** A GlusterFS replicated volume (replica 3) spans all three VMs, providing data redundancy for stateful services. If the node hosting PostgreSQL or Redis fails, those services can be rescheduled to any surviving node with data intact — reducing RTO from hours (backup restore) to minutes (Swarm service constraint update).

**Single PostgreSQL instance.** PostgreSQL runs as a single Swarm service pinned via placement constraint, backed by GlusterFS. This avoids the complexity of streaming replication while keeping RTO well within the Docker stack's tolerance. Streaming replication can be added as a future enhancement if RTO requirements tighten.

**Backup to object storage.** Daily `pg_dump` snapshots and Redis RDB/AOF files are uploaded to Azure Blob Storage (or GCS/S3 on their respective clouds). GlusterFS replication is not a substitute for backup — it protects against node failure, not against data corruption or accidental deletion.

### 3.2 Physical Architecture

```
                          Internet
                              │
                              ▼
                    ┌────────────────────┐
                    │  Azure NSG         │
                    │  Allow: 8080, 3000 │
                    │  Deny: everything  │
                    └─────────┬──────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
   ┌──────────▼──┐  ┌─────────▼──┐  ┌────────▼───┐
   │   Node 1    │  │   Node 2   │  │   Node 3   │
   │ D4s_v5      │  │ D4s_v5     │  │ D4s_v5     │
   │ 4 vCPU 16GB │  │ 4 vCPU 16GB│  │ 4 vCPU 16GB│
   │             │  │            │  │            │
   │ Swarm Mgr   │  │ Swarm Mgr  │  │ Swarm Mgr  │
   └──────┬──────┘  └─────┬──────┘  └──────┬─────┘
          │               │                │
          └───────────────┴────────────────┘
                          │
               ┌──────────▼──────────┐
               │  GlusterFS          │
               │  Replica 3 Volume   │
               │  /mnt/gluster/      │
               │  ├── postgres-data/ │
               │  ├── redis-data/    │
               │  └── polaris-data/  │
               └─────────────────────┘

Azure VNet: 10.0.0.0/16
  Subnet:   10.0.1.0/24 (all 3 nodes)
```

### 3.3 Service Topology

| Service                 | Replicas | Placement                  | Port (internal) | GlusterFS volume |
|-------------------------|----------|----------------------------|-----------------|------------------|
| `airflow-apiserver`     | 2        | Any node                   | 8080            | —                |
| `airflow-scheduler`     | 1        | Pinned: node-1             | —               | —                |
| `airflow-dag-processor` | 1        | Pinned: node-1             | —               | —                |
| `airflow-worker`        | 3        | Distributed (1 per node)   | —               | —                |
| `airflow-triggerer`     | 1        | Pinned: node-1             | —               | —                |
| `airflow-flower`        | 1        | Any node                   | 5555            | —                |
| `postgres`              | 1        | Pinned: node-1 (floatable) | 5432            | `postgres-data/` |
| `redis`                 | 1        | Pinned: node-2 (floatable) | 6379            | `redis-data/`    |
| `polaris`               | 2        | Distributed                | 8181            | `polaris-data/`  |
| `prometheus`            | 1        | Pinned: node-3             | 9090            | —                |
| `grafana`               | 1        | Pinned: node-3             | 3000            | —                |

**Floatable** means: if the pinned node fails, the service can be rescheduled on another node by updating the Swarm placement constraint. GlusterFS ensures data is available on the target node without any manual data migration.

**Publicly exposed via NSG:** `airflow-apiserver:8080`, `grafana:3000`.
All other services are accessible only within the Swarm overlay network.

### 3.4 Networking & Security

**Network topology:**

```
Azure VNet (10.0.0.0/16)
└── data-platform-subnet (10.0.1.0/24)
    ├── node-1: 10.0.1.10
    ├── node-2: 10.0.1.11
    └── node-3: 10.0.1.12

NSG rules (inbound):
  Allow  TCP 8080   0.0.0.0/0   → Airflow UI
  Allow  TCP 3000   0.0.0.0/0   → Grafana
  Allow  TCP 22     <bastion>   → SSH (management only)
  Allow  TCP 2377   10.0.1.0/24 → Swarm manager communication
  Allow  TCP 7946   10.0.1.0/24 → Swarm node discovery
  Allow  UDP 7946   10.0.1.0/24 → Swarm node discovery
  Allow  UDP 4789   10.0.1.0/24 → Swarm overlay (VXLAN)
  Allow  TCP 24007  10.0.1.0/24 → GlusterFS management
  Allow  TCP 49152+ 10.0.1.0/24 → GlusterFS bricks
  Deny   All        0.0.0.0/0
```

**Secrets management:** Azure Key Vault stores all credentials (database passwords, Airflow fernet key, Polaris secrets). A VM managed identity grants read access to Key Vault. Secrets are injected at VM startup via cloud-init and passed to Docker Swarm as `docker secret` objects — never stored in plain-text files or environment variables.

**Access model:** No public SSH port. Use Azure Bastion (or NSG-restricted SSH from a fixed IP) for node access. No direct container exec in production; use Airflow UI and Grafana for operational visibility.

### 3.5 Storage Strategy

**GlusterFS configuration:**

```
Volume type:    Replicated (replica 3)
Brick path:     /data/gluster/brick  (dedicated data disk, not OS disk)
Mount point:    /mnt/gluster         (on all 3 nodes)
Transport:      TCP

Sub-volumes:
  postgres-data/    → PostgreSQL data directory
  redis-data/       → Redis AOF + RDB files
  polaris-data/     → Apache Polaris catalog metadata
```

**PostgreSQL-specific GlusterFS tuning (required):**
```bash
gluster volume set pg-data performance.cache-size 0
gluster volume set pg-data performance.write-behind off
gluster volume set pg-data performance.read-ahead off
gluster volume set pg-data performance.io-cache off
gluster volume set pg-data storage.batch-fsync-delay-usec 0
```
These settings disable GlusterFS caching layers to preserve PostgreSQL's `fsync()` semantics, preventing data corruption under crash recovery.

**Disk layout per node:**

| Disk      | Type             | Size    | Purpose                  |
|-----------|------------------|---------|--------------------------|
| OS disk   | Standard SSD E10 | 128 GiB | Ubuntu OS, Docker Engine |
| Data disk | Premium SSD P15  | 256 GiB | GlusterFS brick          |

**Backup:**
- `pg_dump` runs nightly via a cron container; output is gzip-compressed and uploaded to Azure Blob Storage with 30-day retention
- Redis: AOF persistence enabled; daily RDB snapshots uploaded to Blob Storage
- GlusterFS brick data is not backed up to Blob independently — `pg_dump` and Redis snapshots are the authoritative backups

### 3.6 Observability

**Metrics pipeline:**

```
Airflow (StatsD) → statsd-exporter → Prometheus
PostgreSQL       → postgres-exporter → Prometheus
Redis            → redis-exporter → Prometheus
GlusterFS        → gluster-exporter → Prometheus
Node metrics     → node-exporter (on each VM) → Prometheus
                                                     │
                                                  Grafana
                                                  (dashboards)
                                                     │
                                               Alertmanager
                                               (email/Slack)
```

**Key dashboards:**
- Airflow: DAG success/failure rates, task duration, scheduler heartbeat lag, queue depth
- Celery: worker concurrency, task throughput, queue backlog
- PostgreSQL: connection count, query latency, replication lag (if standby added)
- Redis: memory usage, connected clients, keyspace hits/misses
- Infrastructure: CPU/memory/disk per node, GlusterFS volume status

**Alerting rules (critical):**
- Airflow scheduler heartbeat gap >30 seconds
- Celery queue depth >50 tasks for >10 minutes
- PostgreSQL connection pool exhaustion (>90% of `max_connections`)
- Redis memory usage >80%
- Any node disk utilization >80%
- Any Swarm service with 0 running replicas

### 3.7 Cost Estimation — Azure (Southeast Asia)

All figures are monthly estimates. Pay-as-you-go (PAYG) vs 1-year reserved instance pricing.

| Resource                    | Spec                                     | PAYG/month      | 1-yr Reserved/month |
|-----------------------------|------------------------------------------|-----------------|---------------------|
| VM × 3                      | Standard_D4s_v5 (4 vCPU, 16 GB)          | ~$453           | ~$283               |
| Data disk × 3               | Premium SSD P15 (256 GiB)                | ~$55            | ~$55                |
| OS disk × 3                 | Standard SSD E10 (128 GiB, included)     | ~$0             | ~$0                 |
| Azure Blob Storage          | Backups ~100 GB + operations             | ~$5             | ~$5                 |
| Static Public IP            | 1×                                       | ~$4             | ~$4                 |
| Azure Key Vault             | ~1,000 operations/day                    | ~$3             | ~$3                 |
| Azure Bastion               | Basic SKU (optional; use SSH if omitted) | ~$140 / $0      | ~$140 / $0          |
| **Total (without Bastion)** |                                          | **~$520/month** | **~$350/month**     |
| **Total (with Bastion)**    |                                          | **~$660/month** | **~$490/month**     |

**Notes:**
- Reserved instances require 1-year or 3-year upfront/monthly commitment; 3-year saves ~56%.
- Azure Bastion is recommended for security but adds ~$140/month. An NSG rule restricting SSH to a specific CIDR (e.g. office IP or VPN) is an acceptable zero-cost alternative.
- Southeast Asia compute is ~7–10% more expensive than East US; disk and platform service costs are region-agnostic.
- GCP equivalent (asia-southeast1): 3× e2-standard-4 (~$0.142/hr each) → ~$310/month PAYG; ~$193/month committed use.
- AWS equivalent (ap-southeast-1): 3× m6i.xlarge (~$0.228/hr each) → ~$500/month PAYG; ~$301/month 1-year reserved.

---

## 4. Kubernetes Stack Architecture

### 4.1 Logical Design Principles

**Managed Kubernetes control plane.** The K8s API server, etcd, and controller manager are fully managed (AKS/GKE/EKS). This eliminates the most operationally sensitive component of a Kubernetes cluster from the team's responsibility.

**Self-hosted stateful services via operators.** PostgreSQL (CloudNativePG) and Redis (Opstree Redis Operator with Sentinel) run inside the cluster rather than as managed cloud services. This reduces monthly cost by ~$240–315 compared to Azure Cache for Redis + Azure DB for PG with HA, while maintaining production-grade HA through K8s-native operators.

**Externalized secrets via Key Vault CSI.** The Azure Key Vault CSI driver mounts secrets as read-only tmpfs volumes in pods. Kubernetes Secrets are not used for sensitive values — they would be stored in etcd unencrypted by default and visible via `kubectl get secret`.

**Workload Identity.** Pods authenticate to Azure services (Key Vault, ACR, Blob Storage) using Azure AD Workload Identity — federated OIDC tokens that require no long-lived static credentials. No service account keys, no connection strings in environment variables.

**Separation of node pools.** A dedicated system node pool runs cluster-critical pods (CoreDNS, metrics-server, CSI drivers). A user node pool runs all data platform workloads. The Airflow worker pool can autoscale independently of the scheduler/API pool.

**Zero-downtime operations.** All Deployments use `RollingUpdate` strategy with `maxUnavailable: 0`. PodDisruptionBudgets prevent simultaneous eviction of critical replicas during node drains. Anti-affinity rules spread replicas across availability zones.

### 4.2 Physical Architecture

```
                          Internet
                              │
                   ┌──────────▼──────────┐
                   │  nginx Ingress       │
                   │  TLS termination     │
                   │  /airflow → 8080     │
                   │  /grafana → 3000     │
                   └──────────┬──────────┘
                              │
              ┌───────────────┼─────────────────┐
              │   AKS Cluster (Zone-Redundant)   │
              │                                  │
   ┌──────────▼────────┐    ┌────────────────────▼──┐
   │  System Node Pool │    │   Worker Node Pool     │
   │  2× D2s_v5        │    │   2–6× D4s_v5          │
   │  (zone-redundant) │    │   (autoscale, zone-    │
   │  CoreDNS          │    │    redundant)          │
   │  metrics-server   │    │                        │
   │  CSI drivers      │    │  Airflow components    │
   │  Key Vault CSI    │    │  CloudNativePG         │
   └───────────────────┘    │  Redis Sentinel        │
                            │  Polaris               │
                            │  Prometheus            │
                            │  Grafana               │
                            └────────────────────────┘

Azure VNet: 10.1.0.0/16
  AKS subnet:      10.1.1.0/24
  Service CIDR:    10.2.0.0/24
  DNS service IP:  10.2.0.10
```

### 4.3 Service Topology

**Airflow:**

| Component               | Kind       | Replicas | HPA               | Notes                                      |
|-------------------------|------------|----------|-------------------|--------------------------------------------|
| `airflow-apiserver`     | Deployment | 2        | No                | Anti-affinity across AZs                   |
| `airflow-scheduler`     | Deployment | 2        | No                | Active-active supported in Airflow 2.x+    |
| `airflow-dag-processor` | Deployment | 1        | No                | Stateless; scale to 2 if parsing lag >30s  |
| `airflow-worker`        | Deployment | 2–10     | Yes (queue depth) | HPA scales on Celery queue length via KEDA |
| `airflow-triggerer`     | Deployment | 1        | No                | —                                          |
| `airflow-flower`        | Deployment | 1        | No                | Internal only; not exposed via Ingress     |

**Data services:**

| Component                  | Kind                | Replicas              | HA Mechanism                                             |
|----------------------------|---------------------|-----------------------|----------------------------------------------------------|
| `postgres` (CloudNativePG) | Cluster CR          | 1 primary + 1 replica | Streaming replication; auto-promotion on primary failure |
| `redis` (Opstree Operator) | RedisReplication CR | 1 master + 2 replicas | Sentinel quorum (3 sentinels); auto-failover ~10–30s     |
| `polaris`                  | Deployment          | 2                     | Rolling update; anti-affinity                            |

**Observability:**

| Component      | Kind                                | Notes                                     |
|----------------|-------------------------------------|-------------------------------------------|
| `prometheus`   | StatefulSet (kube-prometheus-stack) | ServiceMonitor CRDs auto-discover targets |
| `grafana`      | Deployment (kube-prometheus-stack)  | Pre-built K8s + Airflow dashboards        |
| `alertmanager` | StatefulSet                         | Bundled in kube-prometheus-stack          |

### 4.4 Networking & Security

**Ingress:**
```
External → Azure Load Balancer → nginx Ingress Controller
  /airflow   → airflow-apiserver:8080  (authenticated)
  /grafana   → grafana:3000            (authenticated)
  Everything else → 404

TLS: cert-manager + Let's Encrypt (or Azure Key Vault certificates)
```

**NetworkPolicy (pod-to-pod isolation):**
```
airflow-* pods:
  Egress allowed to: postgres:5432, redis:6379, polaris:8181
  Ingress allowed from: ingress-nginx namespace only (for apiserver)

postgres pods:
  Ingress allowed from: airflow namespace only
  No egress except intra-cluster replication

redis pods:
  Ingress allowed from: airflow namespace only
  Intra-cluster: sentinel communication allowed

prometheus:
  Ingress allowed from: grafana namespace
  Egress: cluster-wide scrape on /metrics endpoints
```

**Secrets:**
```
Azure Key Vault → CSI driver → tmpfs volume mount in pod
  /mnt/secrets/postgres-password
  /mnt/secrets/airflow-fernet-key
  /mnt/secrets/polaris-credentials
  /mnt/secrets/redis-password
```

### 4.5 Storage

**CloudNativePG (PostgreSQL):**

| PVC                     | StorageClass                     | Size        | Purpose                                  |
|-------------------------|----------------------------------|-------------|------------------------------------------|
| `postgres-primary-data` | managed-premium (Azure Disk P20) | 512 GiB     | Primary data directory                   |
| `postgres-replica-data` | managed-premium (Azure Disk P20) | 512 GiB     | Streaming replica data directory         |
| WAL archive             | Azure Blob Storage               | Pay-per-use | WAL-G continuous archiving; enables PITR |

**Redis (Opstree Operator):**

| PVC                      | StorageClass                 | Size         | Purpose             |
|--------------------------|------------------------------|--------------|---------------------|
| `redis-master-data`      | managed-csi (Azure Disk P10) | 128 GiB      | AOF + RDB           |
| `redis-replica-data` × 2 | managed-csi (Azure Disk P10) | 128 GiB each | Replica persistence |

**Polaris:**

| PVC            | StorageClass                 | Size    | Purpose          |
|----------------|------------------------------|---------|------------------|
| `polaris-data` | managed-csi (Azure Disk P10) | 128 GiB | Catalog metadata |

### 4.6 Observability

**Metrics pipeline:**

```
ServiceMonitor CRDs (auto-discovery)
├── Airflow StatsD → statsd-exporter → Prometheus
├── CloudNativePG → postgres-exporter (bundled)  → Prometheus
├── Redis Exporter (bundled in Opstree operator)  → Prometheus
├── kube-state-metrics                            → Prometheus
├── node-exporter (DaemonSet)                     → Prometheus
└── nginx-ingress metrics                         → Prometheus
                                                       │
                                                   Grafana
                                                  (dashboards +
                                                   alerting rules)
                                                       │
                                                 Alertmanager
                                                 (PagerDuty/
                                                  Slack/email)
```

**KEDA (Kubernetes Event-Driven Autoscaling):**
KEDA scales Airflow workers based on Celery queue depth in Redis. This replaces a static HPA (which uses CPU/memory) with a metric that directly reflects pipeline backlog:
```yaml
triggers:
  - type: redis
    metadata:
      address: redis-master:6379
      listName: default   # Celery default queue
      listLength: "5"     # scale up when >5 tasks queued per worker
```

**Log aggregation:**
Azure Monitor + Log Analytics Workspace collects container logs from all pods. Alternatively, Loki (Grafana stack) can be deployed in-cluster for cost control if log volume is high.

### 4.7 Cost Estimation — Azure (Southeast Asia)

| Resource                        | Spec                                            | PAYG/month      | 1-yr Reserved/month |
|---------------------------------|-------------------------------------------------|-----------------|---------------------|
| AKS system pool × 2             | Standard_D2s_v5 (2 vCPU, 8 GB), zone-redundant  | ~$151           | ~$95                |
| AKS worker pool × 2 (min)       | Standard_D4s_v5 (4 vCPU, 16 GB), zone-redundant | ~$302           | ~$190               |
| AKS control plane               | Standard tier (uptime SLA)                      | ~$73            | ~$73                |
| PostgreSQL PVC × 2              | Azure Disk P20 (512 GiB each)                   | ~$70            | ~$70                |
| Redis PVC × 3                   | Azure Disk P10 (128 GiB each)                   | ~$59            | ~$59                |
| Polaris PVC × 1                 | Azure Disk P10 (128 GiB)                        | ~$20            | ~$20                |
| Azure Container Registry        | Basic SKU                                       | ~$5             | ~$5                 |
| Azure Key Vault                 | ~5,000 operations/day                           | ~$5             | ~$5                 |
| Azure Load Balancer             | Standard, 1 rule                                | ~$18            | ~$18                |
| Azure Monitor / Log Analytics   | ~10 GB logs/day                                 | ~$30            | ~$30                |
| WAL archive (Blob Storage)      | ~50 GB WAL/month                                | ~$3             | ~$3                 |
| **Total (2 worker nodes, min)** |                                                 | **~$736/month** | **~$568/month**     |

**Autoscaling impact:** At peak load (6 worker nodes), the worker pool cost triples to ~$906/month PAYG. At off-peak (1 worker node, if scale-to-zero is enabled), worker cost drops to ~$151/month.

**GCP equivalent (asia-southeast1, minimum config):** ~$625/month PAYG (GKE Autopilot is more predictable but typically ~10–15% more expensive than Standard for this workload profile).

**AWS equivalent (ap-southeast-1, minimum config):** ~$700/month PAYG with EKS + m6i.xlarge nodes.

---

## 5. Cross-Stack Comparison

| Concern                       | Docker Stack                                     | Kubernetes Stack                                  |
|-------------------------------|--------------------------------------------------|---------------------------------------------------|
| **Orchestrator**              | Docker Swarm Mode                                | AKS (managed control plane)                       |
| **Node count**                | 3× fixed                                         | 4–8× autoscaled (system + workers)                |
| **VM size**                   | Standard_D4s_v5 (4 vCPU, 16 GB)                  | D2s_v5 (system) + D4s_v5 (workers)                |
| **PostgreSQL**                | Containerized, single instance, GlusterFS-backed | CloudNativePG: 1 primary + 1 streaming replica    |
| **Redis**                     | Containerized, single instance, GlusterFS-backed | Opstree Operator: 1 master + 2 replicas, Sentinel |
| **Storage HA**                | GlusterFS replica 3 (data survives node loss)    | Azure Managed Disk per pod (zone-redundant)       |
| **Stateful failover**         | Manual (~2–5 min, update Swarm constraint)       | Automatic (~10–30s, operator-managed)             |
| **Airflow worker scaling**    | Manual (`docker service scale`)                  | Automatic (KEDA on Redis queue depth)             |
| **Public exposure**           | NSG: ports 8080, 3000 direct                     | Ingress controller + TLS; single entry point      |
| **Secrets**                   | Azure Key Vault → cloud-init → `docker secret`   | Azure Key Vault CSI driver → pod tmpfs            |
| **Identity**                  | VM Managed Identity                              | Azure Workload Identity (per pod)                 |
| **Observability**             | Prometheus + Grafana (containers)                | kube-prometheus-stack (Helm) + KEDA metrics       |
| **Deployment mechanism**      | `docker stack deploy`                            | `helm upgrade`                                    |
| **Estimated RTO**             | 2–5 minutes (GlusterFS + manual reschedule)      | <30 seconds (operator auto-failover)              |
| **Estimated RPO**             | ~24 hours (nightly pg_dump)                      | ~5 minutes (CloudNativePG WAL archiving)          |
| **Monthly cost (Azure, min)** | ~$328–486                                        | ~$547–703                                         |
| **Operational complexity**    | Low–Medium                                       | Medium–High                                       |

---

## 6. Migration Path: Docker → Kubernetes

Migration is non-destructive. The Docker stack remains running during migration; cutover is a DNS change.

### Phase 1 — Parallel infrastructure (weeks 1–2)
1. Provision AKS cluster and node pools via Terraform
2. Deploy all K8s stack services (without Airflow DAGs)
3. Validate connectivity: all services healthy, Prometheus scraping, Grafana dashboards populated

### Phase 2 — Data migration (week 3)
1. Take a `pg_dump` from the Docker stack PostgreSQL
2. Restore into the CloudNativePG primary on the K8s cluster
3. Validate row counts and schema integrity
4. Pause DAG scheduling on Docker stack (`airflow dags pause --all`)

### Phase 3 — Cutover (week 3–4)
1. Deploy DAG files to K8s cluster (same `dags/` directory, mounted via ConfigMap or git-sync)
2. Update DNS/load balancer to point Airflow UI and Grafana to K8s ingress
3. Resume DAG scheduling on K8s cluster
4. Monitor for 48 hours before decommissioning Docker stack

### Phase 4 — Decommission (week 5)
1. Run Docker stack in read-only mode for 1 additional week (safety net)
2. Archive final `pg_dump` snapshot to cold Blob Storage
3. Destroy Docker stack Terraform resources
4. Remove GlusterFS volumes and VM disks

**Key constraint:** Airflow DAG files, plugins, and connection configs must be environment-agnostic — no hardcoded hostnames or IP addresses. Both stacks resolve service names via Docker Swarm overlay DNS and Kubernetes CoreDNS respectively; connection configs using service names (`postgres`, `redis`) work identically in both environments.

---

## 7. Cost Optimization

### Docker Stack

**Strategy 1 — Scheduled VM start/stop**

Not all 3 nodes need to run 24/7. Designate Node 1 as always-on (it hosts PostgreSQL, Redis, and the Swarm primary manager) and Nodes 2/3 as schedulable. Stopping Nodes 2/3 during off-hours (e.g. 10pm–6am weekdays, all weekend) saves ~50% of their compute cost.

```
Node 1  always-on       PostgreSQL, Redis, Swarm manager, Airflow core
Node 2  schedulable     Airflow worker, Polaris replica
Node 3  schedulable     Airflow worker, Prometheus, Grafana
```

**GlusterFS quorum note:** With replica 3, GlusterFS tolerates 1 brick offline (2/3 quorum required for writes). Stopping 1 node keeps the volume healthy. Stopping 2 nodes simultaneously makes the volume read-only. Never stop more than 1 node at a time.

| Cloud | Mechanism                                                                      |
|-------|--------------------------------------------------------------------------------|
| Azure | Azure Automation runbook on a cron schedule; `Start-AzVM` / `Stop-AzVM`        |
| GCP   | Cloud Scheduler + Cloud Functions calling `instances.stop` / `instances.start` |
| AWS   | AWS Instance Scheduler (native) or EventBridge + Lambda                        |

**Strategy 2 — Spot/preemptible VMs for worker nodes**

Nodes 2 and 3 run only stateless Airflow workers and replicated services. They are safe to run on Spot VMs (Azure), Preemptible VMs (GCP), or Spot Instances (AWS), saving 60–90% on those nodes. Celery handles worker eviction gracefully — in-flight tasks are re-queued and retried.

**Eviction policy must be set to Stop/Deallocate (not Delete)** on Azure Spot VMs, to preserve the GlusterFS brick data on the data disk.

**Strategy 3 — Reserved instances for Node 1**

Node 1 runs continuously. A 1-year reserved instance commitment saves ~37% (Azure) on that VM.

**Estimated monthly cost with all strategies applied (Azure):**

| Configuration                                     | Monthly cost |
|---------------------------------------------------|--------------|
| PAYG, all 3 nodes always-on                       | ~$486        |
| Scheduled stop Nodes 2+3 (~50% uptime)            | ~$380        |
| Spot VMs for Nodes 2+3 + scheduled stop           | ~$265        |
| Reserved Node 1 + Spot Nodes 2+3 + scheduled stop | ~$220        |

---

### Kubernetes Stack

**Strategy 1 — KEDA scale-to-zero for worker nodes**

The worker node pool autoscales to 0 when no tasks are queued. Combined with KEDA monitoring the Celery Redis queue, new worker nodes provision in ~2–3 minutes when DAGs start running. The system node pool (2 nodes) always runs.

This is the single most impactful cost lever: at off-peak hours the worker pool cost drops to $0.

**Strategy 2 — Spot node pool for workers**

The worker node pool uses Azure Spot VMs. K8s tolerations and node labels ensure only Airflow worker pods (and other non-critical workloads) land on spot nodes. System pods, CloudNativePG, and Redis Sentinel run on the regular system pool.

```yaml
# Node pool config (Terraform)
priority        = "Spot"
eviction_policy = "Delete"
spot_max_price  = -1   # pay up to on-demand price

# Pod toleration for worker Deployment
tolerations:
  - key: "kubernetes.azure.com/scalesetpriority"
    operator: "Equal"
    value: "spot"
    effect: "NoSchedule"
```

**Strategy 3 — Reserved instances for system node pool**

The system pool runs 24/7. A 1-year reservation saves ~37% on those 2 nodes.

**Strategy 4 — AKS cluster stop (dev/staging only)**

`az aks stop` deallocates all node VMs. Only storage (PVCs, disks) is billed. Saves ~100% of compute during nights and weekends for non-production clusters. Resume with `az aks start` (~5 minute cold-start.

**Not recommended for production** — violates the zero-downtime principle. Use scale-to-zero instead.

**Strategy 5 — Log Analytics data cap**

Set a daily ingestion cap on the Log Analytics workspace to avoid runaway log costs. If log volume consistently exceeds 5 GB/day, replace Azure Monitor with in-cluster Loki (Grafana stack), which stores logs on cheap Azure Blob Storage instead of Log Analytics pricing (~$2.76/GB ingested).

**Estimated monthly cost with all strategies applied (Azure):**

| Configuration                                       | Monthly cost |
|-----------------------------------------------------|--------------|
| PAYG, 2 worker nodes always-on                      | ~$703        |
| KEDA scale-to-zero (~50% worker uptime)             | ~$563        |
| Spot worker pool + scale-to-zero                    | ~$420        |
| Reserved system pool + Spot workers + scale-to-zero | ~$380        |

---

## 8. Failover Runbooks

RTO and RPO targets per stack:

|                | Docker Stack                 | Kubernetes Stack            |
|----------------|------------------------------|-----------------------------|
| **RTO target** | < 10 minutes                 | < 2 minutes                 |
| **RPO target** | < 24 hours (nightly pg_dump) | < 5 minutes (WAL archiving) |

---

### Docker Stack

#### Scenario A — Single worker node failure (Node 2 or 3)

**Detection:** Prometheus alert `SwarmNodeUnreachable` + `node_exporter` scrape failure for the affected node.

**Impact:** 1/3 of worker capacity lost. GlusterFS degrades to 2/3 bricks (still writable). Running tasks may fail and retry via Celery's retry policy. No data loss.

**Recovery:**
```
1. Confirm node is unreachable: `docker node ls` from Node 1
2. Swarm automatically reschedules worker replicas onto the 2 surviving nodes
3. Verify workers are running: `docker service ps airflow-worker`
4. Tasks that were mid-execution are re-queued; monitor Flower UI for retries
5. Repair or replace the failed node
6. Re-join node to Swarm: `docker swarm join --token <token> <manager-ip>:2377`
7. Re-label node: `docker node update --label-add glusterfs=brick node-N`
8. Re-add GlusterFS brick: `gluster volume add-brick <volume> <node>:/data/gluster/brick`
9. Trigger GlusterFS rebalance: `gluster volume rebalance <volume> start`
```

**Estimated RTO:** Automatic for workers (~1 min Swarm reschedule). Node repair is background work.

---

#### Scenario B — Node 1 failure (PostgreSQL + Airflow core)

**Detection:** Prometheus alerts `PostgresDown`, `AirflowSchedulerHeartbeatMissing` + `node_exporter` scrape failure for Node 1.

**Impact:** Airflow scheduling stops. No new tasks dispatched. Running tasks complete or timeout. GlusterFS degrades to 2/3 bricks (writable). No data loss.

**Recovery:**
```
1. Confirm Node 1 is down (Azure Portal / `az vm show -n node-1`)
2. From Node 2 — float PostgreSQL to Node 2:
     docker service update \
       --constraint-rm 'node.hostname==node-1' \
       --constraint-add 'node.hostname==node-2' postgres
3. Verify PostgreSQL starts and data is intact:
     docker exec $(docker ps -q -f name=postgres) \
       psql -U airflow -c "SELECT count(*) FROM dag_run;"
4. Float Airflow core services to Node 2:
     docker service update --constraint-rm 'node.hostname==node-1' \
       --constraint-add 'node.hostname==node-2' airflow-scheduler
     # Repeat for airflow-dag-processor, airflow-triggerer
5. Verify GlusterFS volume is healthy:
     gluster volume status
6. Verify Airflow scheduler heartbeat resumes (Grafana dashboard)
7. Repair Node 1; when back online, reverse the constraint updates
```

**Estimated RTO:** 2–5 minutes.

---

#### Scenario C — Majority node failure (2+ nodes, Swarm quorum loss)

**Detection:** Swarm API unresponsive. Prometheus scrapes fail for 2+ nodes. GlusterFS volume goes read-only (only 1/3 bricks available).

**Impact:** Swarm cannot accept service updates. GlusterFS read-only. Running containers may continue in isolation but cannot be rescheduled.

**Recovery:**
```
1. Attempt to restore one failed node first (Azure Portal VM restart)
   — If successful, this restores Swarm quorum (2/3) and GlusterFS writes. Run Scenario B.

2. If nodes are unrecoverable, force new Swarm quorum from the surviving manager:
     docker swarm init --force-new-cluster
   WARNING: This creates a single-manager cluster. All services restart on the surviving node.

3. If GlusterFS data is needed from the single brick before any writes:
     mount -t glusterfs localhost:/gfs-volume /mnt/recovery
     # Copy data out before making any writes

4. If all nodes are unrecoverable — restore from backup:
     a. Provision 3 new VMs via Terraform
     b. Re-initialise Swarm and GlusterFS
     c. Restore PostgreSQL from latest pg_dump in Azure Blob Storage:
          az storage blob download --container-name backups \
            --name latest/airflow.sql.gz --file /tmp/airflow.sql.gz
          gunzip /tmp/airflow.sql.gz
          psql -U airflow < /tmp/airflow.sql
     d. Restore Redis snapshot from Blob Storage (optional; Celery queue is transient)
     e. Redeploy Swarm stack: `docker stack deploy -c stack.yml data-platform`
```

**Estimated RTO:** 30 minutes (node recoverable) — 4 hours (full restore from backup).

---

### Kubernetes Stack

#### Scenario A — Pod failure

**Detection:** Grafana shows pod restart counter incrementing. `kubectl get pods` shows `CrashLoopBackOff` or `Error`.

**Impact:** Kubernetes reschedules the pod automatically. Typically zero user impact.

**Action:** None for transient failures. Investigate if restart count exceeds 5 within 10 minutes — likely a configuration or OOM issue. Check logs: `kubectl logs <pod> --previous`.

**Estimated RTO:** Automatic (~30 seconds for pod reschedule + readiness probe).

---

#### Scenario B — Worker node failure

**Detection:** Prometheus alert `KubeNodeNotReady`. `kubectl get nodes` shows `NotReady`.

**Impact:** Pods on the failed node are evicted and rescheduled on surviving worker nodes. KEDA may scale up a replacement node if queue depth increases.

**Action:** None required. Cluster autoscaler provisions a replacement node automatically. Monitor:
```
kubectl get nodes -w
kubectl get pods -o wide | grep Pending
```

**Estimated RTO:** 2–5 minutes (pod reschedule + new node provision if needed).

---

#### Scenario C — PostgreSQL primary failure (CloudNativePG)

**Detection:** Prometheus alert `CNPGPrimaryNotAvailable`. CloudNativePG operator emits a `FailoverInitiated` Kubernetes event.

**Impact:** CloudNativePG automatically promotes the streaming replica to primary. ~30-second gap during promotion where write queries fail.

**Action:**
```
1. Verify promotion:
     kubectl get cluster postgres-cluster -o jsonpath='{.status.currentPrimary}'
2. If Airflow API server cached a stale primary connection, restart it:
     kubectl rollout restart deployment/airflow-apiserver
3. CloudNativePG automatically provisions a new replica after promotion.
   Monitor: kubectl get pods -l cnpg.io/cluster=postgres-cluster
```

**Estimated RTO:** ~30 seconds (automatic).

---

#### Scenario D — Redis master failure (Sentinel)

**Detection:** Prometheus alert `RedisMasterDown`. Opstree operator logs show sentinel election.

**Impact:** Sentinel quorum promotes a replica to master in ~10–30 seconds. Celery workers reconnect automatically via the Sentinel endpoint (not a direct Redis IP).

**Action:** Monitor Grafana Redis dashboard for reconnection. Opstree operator provisions a replacement replica. No manual steps required unless Sentinel election fails (rare — requires 2+ sentinel pods to be down simultaneously).

**Estimated RTO:** ~10–30 seconds (automatic).

---

#### Scenario E — Availability zone failure

**Detection:** Azure Service Health alert. Widespread `KubeNodeNotReady` across one AZ. Prometheus scrapes drop for affected nodes.

**Impact:** Worker nodes in the affected AZ are lost. System pool nodes in other AZs remain healthy (zone-redundant pool). AKS reschedules all pods. CloudNativePG and Redis Sentinel elect new leaders from replicas in surviving AZs.

**Action:**
```
1. Verify system pool nodes in surviving AZs are Ready:
     kubectl get nodes -l agentpool=system
2. Allow cluster autoscaler to provision replacement worker nodes
   in surviving AZs (automatic, ~3–5 minutes)
3. Verify PostgreSQL has a healthy primary:
     kubectl get cluster postgres-cluster -o jsonpath='{.status.currentPrimary}'
4. Verify Redis Sentinel has elected a master:
     kubectl exec -it redis-master-0 -- redis-cli -a $REDIS_PASSWORD INFO replication
5. Verify Airflow API server is accessible via Ingress:
     curl -I https://<ingress-host>/airflow/health
6. Monitor task queue for any stalled tasks; manually retry if needed
```

**Estimated RTO:** 5–10 minutes.
