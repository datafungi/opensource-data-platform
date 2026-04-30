# SeaweedFS — Setup and Operations

SeaweedFS provides S3-compatible object storage for Airflow remote logging, Iceberg
table data, and database backups. It replaces Azure Blob Storage with a fully
self-hosted, Apache 2.0 licensed solution.

---

## Architecture

```
seaweedfs-master  (node1, stateful)
  └── cluster coordinator, volume placement decisions

seaweedfs-volume  (global — one instance per node)
  └── actual blob storage, auto-registered with master

seaweedfs-filer   (node1, stateful)
  └── metadata index + S3 gateway (port 8333)
  └── filer UI (port 8888, Tailscale only)
```

---

## Bootstrap (first deploy)

### 1. Create GlusterFS directories

```bash
mkdir -p /mnt/gluster/seaweedfs-master
mkdir -p /mnt/gluster/seaweedfs-volume
```

### 2. Create Docker secrets

```bash
echo -n "your-access-key" | docker secret create seaweedfs_access_key -
echo -n "your-secret-key" | docker secret create seaweedfs_secret_key -
```

### 3. Deploy

```bash
docker stack deploy -c infra/docker-stack/compose/storage.yaml data-platform
```

### 4. Create required buckets

```bash
AWS_ACCESS_KEY_ID=your-access-key \
AWS_SECRET_ACCESS_KEY=your-secret-key \
  aws --endpoint-url http://node1-ip:8333 s3 mb s3://airflow-logs
  aws --endpoint-url http://node1-ip:8333 s3 mb s3://backups
  aws --endpoint-url http://node1-ip:8333 s3 mb s3://iceberg-warehouse
```

---

## Airflow Remote Logging Connection

Store in Vault at `secret/airflow/connections/seaweedfs_logs`:

```
aws://<key>:<secret>@seaweedfs-filer:8333?endpoint_url=http%3A%2F%2Fseaweedfs-filer%3A8333&region_name=us-east-1
```

The `apache-airflow-providers-amazon` package handles S3-compatible logging
when pointed at a custom endpoint URL.

---

## Iceberg Table Storage

Trino and Spark access Iceberg tables at `s3a://iceberg-warehouse/` with:

```
fs.s3a.endpoint=http://seaweedfs-filer:8333
fs.s3a.access.key=<key>
fs.s3a.secret.key=<secret>
fs.s3a.path.style.access=true
fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem
```

---

## Prometheus Metrics

SeaweedFS exposes Prometheus metrics at port 9324 on each service.
Add to `infra/docker-stack/compose/prometheus/prometheus.yml`:

```yaml
- job_name: seaweedfs
  static_configs:
    - targets:
      - seaweedfs-master:9333
      - seaweedfs-filer:9334
      - seaweedfs-volume:9325
```

---

## Filer UI

Access the SeaweedFS filer UI at `http://<tailscale-ip>:8888`.
Ensure port 8888 is allowed from the Tailscale subnet in the firewall configuration.
