# Opensource Data Platform

A local-first data platform for building and testing data pipelines, plus an
optional Azure Terraform lab for practicing infrastructure deployment.

## Stack

- Apache Airflow with CeleryExecutor
- Redis
- PostgreSQL
- ClickHouse
- Marquez and OpenLineage
- MinIO
- Mock ServiceNow API
- Docker Compose
- Terraform for the Azure lab

## Layout

```text
.
├── dags/                  # Airflow DAGs and custom plugins
├── infra/
│   ├── docker/            # Airflow, Postgres, ClickHouse, MinIO, Marquez, mock APIs
│   ├── scripts/           # Azure VM start/stop helpers
│   └── terraform/         # Azure data infrastructure lab
├── tests/
├── pyproject.toml
└── Makefile
```

## Local Development

Prerequisites:

- Docker and Docker Compose
- Python 3.12
- `uv`
- 8 GB or more RAM

Start the local platform:

```bash
cp .env.example .env
uv sync --dev
make up
```

Start one component:

```bash
make up component=airflow
make up component=postgres
make up component=clickhouse
make up component=minio
make up component=mock-servicenow
```

## Service Access

| Service             | URL                   | Credentials             |
|---------------------|-----------------------|-------------------------|
| Airflow UI          | http://localhost:8080 | airflow / airflow       |
| Flower              | http://localhost:5555 | profile: flower         |
| Marquez Web         | http://localhost:3000 | none                    |
| Marquez API         | http://localhost:5000 | none                    |
| MinIO Console       | http://localhost:9001 | minioadmin / minioadmin |
| Mock ServiceNow API | http://localhost:8001 | admin / admin           |

## Azure Lab

The Terraform lab in `infra/terraform` provisions a small VM-based data
infrastructure environment in Southeast Asia.

Current shape:

- 3 Ubuntu VMs: `vm-01-control`, `vm-02-worker-a`, `vm-03-worker-b`
- VM size: `Standard_D4as_v5`
- 32 GiB OS disk and 64 GiB managed data disk per VM
- Shared private VNet with static private IPs
- Tailscale-first access
- Jumpbox public IP disabled by default
- NAT Gateway enabled for explicit outbound internet access
- Daily shutdown and inactivity-based VM deallocation

Use it for Airflow, Dagster, Redis, PostgreSQL, ClickHouse, Cassandra, MongoDB,
OpenMetadata, Prometheus, and Grafana practice.

See `infra/terraform/README.md` for setup, cost notes, teardown, and
soft-delete cleanup.

## Development

```bash
uv sync --dev
uv run pytest
uv run ruff check .
uv run ruff format .
```

## License

GNU General Public License v3. See `LICENSE`.
