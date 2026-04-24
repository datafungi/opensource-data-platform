# Infrastructure

This directory contains all infrastructure-as-code and container definitions for the data platform.

## Structure

```
infra/
├── docker/
│   ├── images/           # Dockerfiles for custom-built images
│   │   └── airflow/      # Extended Airflow image (localairflow:latest)
│   └── local/            # Docker Compose stacks for local development
│       ├── airflow/      # Airflow cluster + Redis
│       ├── clickhouse/   # ClickHouse analytical database
│       ├── marquez/      # Marquez lineage API + Web UI
│       ├── minio/        # MinIO object storage
│       └── postgres/     # Shared PostgreSQL (airflow + marquez databases)
├── docker-stack/         # Production infrastructure (Docker Swarm on cloud VMs)
│   ├── compose/          # Shared Swarm stack definitions
│   ├── scripts/          # Shared runtime/bootstrap scripts
│   └── providers/
│       ├── azure/        # Azure-specific IaC and deployment automation
│       │   ├── ansible/
│       │   └── terraform/
│       ├── aws/
│       │   └── terraform/
│       └── gcp/
│           └── terraform/
├── k8s-stack/            # Kubernetes stack (planned)
└── ARCHITECTURE.md       # Full architecture reference for all stacks and clouds
```

## Local Development

All local services are managed via the project root `Makefile`:

```bash
make build                    # Build localairflow:latest image
make up                       # Start all services
make up component=airflow     # Start only Airflow (+ Postgres dependency)
make up component=marquez     # Start only Marquez (+ Postgres dependency)
make up component=minio       # Start only MinIO
make up component=clickhouse  # Start only ClickHouse
make down                     # Stop all services
```

Services share the external Docker network `data-platform` (auto-created by `make up`).

## Production (Docker Stack)

Cloud VM-based Docker Swarm cluster. Currently implemented for **Azure**; GCP and AWS are planned.

Provision with Terraform:

```bash
cd infra/docker-stack/providers/azure/terraform
terraform init
terraform plan
terraform apply
```

After `apply`, run `infra/docker-stack/providers/azure/terraform/scripts/bootstrap-gluster.sh` to configure the GlusterFS shared volume across all three nodes.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for full design decisions, cost estimates, and cross-cloud comparison.
