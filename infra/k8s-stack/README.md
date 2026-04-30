# Kubernetes Self-Hosted Stack

Deploys the full data platform on a self-hosted Kubernetes cluster using
[helmfile](https://helmfile.readthedocs.io/). Works with **k3s** (recommended for
bare-metal) or any kubeadm-provisioned cluster.

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| `kubectl` | ≥ 1.28 | Kubernetes CLI |
| `helm` | ≥ 3.14 | Chart package manager |
| `helmfile` | ≥ 0.165 | Declarative Helm release management |
| A running Kubernetes cluster | ≥ 1.28 | k3s or kubeadm |

---

## Cluster Setup (k3s — recommended)

k3s is a lightweight, production-grade Kubernetes distribution that installs in under
a minute on any Linux VM (bare-metal or cloud).

```bash
# On the first node (control plane + embedded etcd)
curl -sfL https://get.k3s.io | sh -

# Retrieve the join token
cat /var/lib/rancher/k3s/server/node-token

# On additional nodes
curl -sfL https://get.k3s.io | K3S_URL=https://<node1-ip>:6443 \
  K3S_TOKEN=<join-token> sh -

# Copy kubeconfig to your workstation
scp root@<node1-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/<node1-ip>/g' ~/.kube/config
```

k3s includes:
- **Traefik** ingress controller
- **CoreDNS**
- **local-path-provisioner** (StorageClass `local-path` for PersistentVolumes)
- **Flannel** CNI

---

## Storage

The default `local-path` StorageClass works for single-node clusters and development.
For multi-node production clusters, use a distributed storage provider:

- **Longhorn** — simple, GUI-based, good for 3-node clusters
- **OpenEBS** — more configuration options, good for bare-metal

```bash
# Install Longhorn (optional — for multi-node HA storage)
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace
```

---

## Deploy

### 1. Create the namespace

```bash
kubectl create namespace data-platform
kubectl create namespace monitoring
```

### 2. Create required Kubernetes Secrets

```bash
# Vault Airflow token (create after Vault is initialized — see step 5)
kubectl create secret generic vault-airflow-token \
  --from-literal=VAULT_TOKEN=<airflow-vault-token> \
  -n data-platform

# PostgreSQL
kubectl create secret generic postgres-airflow-secret \
  --from-literal=password=<pg-password> \
  -n data-platform

# Redis
kubectl create secret generic redis-secret \
  --from-literal=password=<redis-password> \
  -n data-platform

# ClickHouse
kubectl create secret generic clickhouse-secret \
  --from-literal=password=<ch-password> \
  -n data-platform

# SeaweedFS S3 credentials
kubectl create secret generic seaweedfs-s3-secret \
  --from-literal=s3.json='{"identities":[{"name":"admin","credentials":[{"accessKey":"<key>","secretKey":"<secret>"}],"actions":["Admin","Read","List","Tagging","Write"]}]}' \
  -n data-platform
```

### 3. Install chart repositories and sync releases

```bash
cd infra/k8s-stack
helmfile repos   # add all chart repositories
helmfile sync    # deploy all releases
```

### 4. Monitor rollout

```bash
kubectl get pods -n data-platform -w
kubectl get pods -n monitoring -w
```

### 5. Bootstrap Vault

```bash
VAULT_POD=$(kubectl get pod -n data-platform -l app.kubernetes.io/name=vault -o name | head -1)

# Initialize
kubectl exec -n data-platform $VAULT_POD -- vault operator init

# Unseal (repeat 3x with different keys)
kubectl exec -n data-platform $VAULT_POD -- vault operator unseal

# Enable KV v2 and write secrets (see airflow_secrets_management.md)
kubectl exec -n data-platform $VAULT_POD -- vault secrets enable -path=secret kv-v2
```

### 6. Create SeaweedFS buckets

```bash
# Port-forward the SeaweedFS filer
kubectl port-forward -n data-platform svc/seaweedfs-filer-svc 8333:8333 &

AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws --endpoint-url http://localhost:8333 s3 mb s3://airflow-logs
  aws --endpoint-url http://localhost:8333 s3 mb s3://backups
  aws --endpoint-url http://localhost:8333 s3 mb s3://iceberg-warehouse
```

---

## Updating a Release

```bash
# Edit the relevant values file under helm/base/, then:
helmfile diff    # preview changes
helmfile apply   # apply only changed releases
```

---

## Overlays

The `helm/overlays/on-prem/` directory is reserved for environment-specific patches
(e.g., custom StorageClass names, node affinity rules, ingress hostnames). Add a
`helmfile.yaml` there that extends the base using helmfile's `bases:` feature.
