# Opensource Data Platform

A containerized Apache Airflow environment for data pipeline orchestration, built for local development with a distributed execution architecture.

## Stack

- **Apache Airflow 3.1.7** — workflow orchestration
- **CeleryExecutor** with Redis broker — distributed task execution
- **PostgreSQL 16** — Airflow metadata database
- **Docker Compose** — local service orchestration
- **Python 3.12** / **uv** — dependency management

## Project Structure

```
.
├── config/airflow.cfg          # Airflow configuration
├── dags/                       # DAG definitions
│   └── plugins/                # Custom plugins
├── docker/
│   └── airflow/
│       ├── Dockerfile
│       └── docker-compose.yaml
├── logs/                       # Runtime logs (auto-created)
├── tests/
└── pyproject.toml
```

## Getting Started

**Prerequisites:** Docker, Docker Compose, 4GB+ RAM

```bash
# Clone the repo
git clone <repository-url>
cd opensource-data-platform

# Start all services
docker compose -f docker/airflow/docker-compose.yaml up -d
```

Access the Airflow UI at **http://localhost:8080** with credentials `airflow` / `airflow`.

## Services

| Service           | Port | Description                      |
|-------------------|------|----------------------------------|
| API Server        | 8080 | Airflow REST API + UI            |
| Flower            | 5555 | Celery task monitoring (optional)|
| PostgreSQL        | —    | Metadata database                |
| Redis             | —    | Celery message broker            |

To start Flower: `docker compose --profile flower up -d`

## Adding DAGs

Place Python DAG files in the `dags/` directory. They are automatically picked up by the DAG processor. Custom operators and hooks go in `dags/plugins/`.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
