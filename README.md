# Opensource Data Platform

A containerized local development platform for Apache Airflow data pipelines, featuring distributed execution, data lineage tracking, S3-compatible object storage, and a mock ServiceNow API for pipeline development without external dependencies.

## Stack

- **Apache Airflow 3.1.7** — workflow orchestration (CeleryExecutor)
- **Redis** — Celery message broker
- **PostgreSQL 16** — shared metadata database (Airflow + Marquez)
- **Marquez** — data lineage tracking via OpenLineage
- **MinIO** — S3-compatible object storage
- **Mock ServiceNow API** — local ServiceNow Table API simulator backed by DuckDB
- **Salesforce synthetic data setup** — Snowfakery recipe, enrichment/loader scripts, and metadata for pipeline analytics
- **Python 3.12** / **uv** — dependency management
- **Docker Compose** — local service orchestration

## Project Structure

```
.
├── dags/                            # Airflow DAG definitions
│   └── plugins/
│       ├── operators/               # Custom operators
│       └── providers/               # Custom providers
├── setup/
│   ├── context/
│   │   └── BUSINESS_MODEL.md        # Business assumptions for synthetic data generation
│   └── salesforce/
│       ├── recipes/                 # Snowfakery recipe(s)
│       ├── scripts/                 # Auth, purge, enrich, load utilities
│       ├── docs/                    # Pipeline analytics playbook (SOQL)
│       ├── force-app/               # Salesforce metadata (fields, permission set)
│       ├── data/                    # Generated CSV artifacts
│       ├── Makefile                 # Salesforce workflow shortcuts
│       └── README.md
├── docker/
│   ├── airflow/
│   │   ├── Dockerfile               # Custom Airflow image
│   │   └── docker-compose.yaml
│   ├── marquez/
│   │   └── docker-compose.yaml
│   ├── minio/
│   │   └── docker-compose.yaml
│   ├── mock-servicenow/
│   │   ├── Dockerfile
│   │   ├── docker-compose.yaml
│   │   ├── requirements.txt
│   │   └── app/                     # FastAPI mock application
│   └── postgres/
│       ├── docker-compose.yaml
│       └── init-db.sh               # Creates airflow + marquez databases
├── tests/
│   ├── mock-servicenow/             # Mock API tests
│   └── salesforce/                  # Salesforce setup script unit tests
├── pyproject.toml
└── Makefile
```

## Getting Started

**Prerequisites:** Docker, Docker Compose, Python 3.12, uv, 8GB+ RAM

```bash
# Copy and configure environment variables
cp .env.example .env   # then edit credentials as needed

# Install Python dependencies
uv sync --dev

# Start all services
make up

# Or start individual components
make up component=postgres
make up component=airflow
make up component=marquez
make up component=minio
make up component=mock-servicenow
```

## Service Access

| Service             | URL                   | Credentials             |
| ------------------- | --------------------- | ----------------------- |
| Airflow UI          | http://localhost:8080 | airflow / airflow       |
| Flower              | http://localhost:5555 | (profile: flower)       |
| Marquez Web         | http://localhost:3000 | —                       |
| Marquez API         | http://localhost:5000 | —                       |
| MinIO Console       | http://localhost:9001 | minioadmin / minioadmin |
| Mock ServiceNow API | http://localhost:8001 | admin / admin           |

## Mock ServiceNow API

A local FastAPI service that mimics the [ServiceNow Table API](https://developer.servicenow.com/dev.do#!/reference/api/latest/rest/c_TableAPI), backed by DuckDB. Use it to develop and test Airflow DAGs that pull from ServiceNow without a real instance.

**Supported tables:** `incident`, `problem`, `change_request`, `sys_user`, `cmdb_ci`

**Default dataset:** 1 million records per table (configurable via `MOCK_SN_TOTAL_RECORDS`). Generated on first startup using DuckDB SQL and persisted to a named Docker volume — subsequent restarts skip generation.

```bash
# Fetch incidents
curl -u admin:admin "http://localhost:8001/api/now/table/incident?sysparm_limit=10"

# Filter by field values
curl -u admin:admin "http://localhost:8001/api/now/table/incident?sysparm_query=state=1^priority=2"

# Project specific fields
curl -u admin:admin "http://localhost:8001/api/now/table/incident?sysparm_fields=sys_id,number,state"

# Paginate
curl -u admin:admin "http://localhost:8001/api/now/table/incident?sysparm_limit=1000&sysparm_offset=50000"

# Health check (no auth required)
curl http://localhost:8001/health
```

To use the mock from inside the Docker network (e.g. from an Airflow DAG), set the ServiceNow base URL to `http://mock-servicenow:8000`.

## Salesforce Synthetic Data Setup

The repository includes a dedicated Salesforce setup for generating and loading synthetic pipeline data aligned to a hybrid Services + SaaS business model.

Key locations:

- `setup/context/BUSINESS_MODEL.md`
- `setup/salesforce/README.md`
- `setup/salesforce/docs/PIPELINE_ANALYTICS_PLAYBOOK.md`

Typical workflow:

```bash
cd setup/salesforce
make help
make full-refresh TARGET_ORG=dev-org
make analyze-year1 TARGET_ORG=dev-org START_DATE=2024-04-16 END_DATE=2025-04-16
```

Requirements for Salesforce workflow:

- Salesforce CLI (`sf`)
- Authenticated org alias (default expected by scripts: `dev-org`)

## Development

```bash
uv sync --dev          # Install all dependencies
uv run pytest          # Run all tests
uv run ruff check .    # Lint
uv run ruff format .   # Format
```

## Adding DAGs

Place `.py` files in `dags/`. Custom operators and providers go in `dags/plugins/operators/` and `dags/plugins/providers/`. The `dags/` directory is volume-mounted into all Airflow containers.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
