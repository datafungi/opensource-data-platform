POSTGRES_COMPOSE    := infra/docker/local/postgres/docker-compose.yaml
AIRFLOW_COMPOSE     := infra/docker/local/airflow/docker-compose.yaml
MARQUEZ_COMPOSE     := infra/docker/local/marquez/docker-compose.yaml
MINIO_COMPOSE       := infra/docker/local/minio/docker-compose.yaml
MOCK_SN_COMPOSE     := infra/docker/local/mock-servicenow/docker-compose.yaml
CLICKHOUSE_COMPOSE  := infra/docker/local/clickhouse/single-node/docker-compose.yaml
AIRFLOW_IMAGE       := localairflow:latest

# Compose files per component (dependencies included)
COMPOSE_FILES_postgres         := $(POSTGRES_COMPOSE)
COMPOSE_FILES_airflow          := $(POSTGRES_COMPOSE) $(AIRFLOW_COMPOSE)
COMPOSE_FILES_marquez          := $(POSTGRES_COMPOSE) $(MARQUEZ_COMPOSE)
COMPOSE_FILES_minio            := $(MINIO_COMPOSE)
COMPOSE_FILES_mock-servicenow  := $(MOCK_SN_COMPOSE)
COMPOSE_FILES_clickhouse       := $(CLICKHOUSE_COMPOSE)
ALL_COMPOSE_FILES              := $(POSTGRES_COMPOSE) $(AIRFLOW_COMPOSE) $(MARQUEZ_COMPOSE) $(MINIO_COMPOSE) $(CLICKHOUSE_COMPOSE)

# Support both `make up component=foo` (variable override) and `make up foo` (goal-based)
ifdef component
  COMPONENT := $(component)
else
  COMPONENT := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq ($(COMPONENT),)
    $(eval $(COMPONENT):;@:)
  endif
endif

ifneq ($(COMPONENT),)
  SELECTED_FILES := $(COMPOSE_FILES_$(COMPONENT))
  # Don't remove orphans for single-component deploys — other components are not orphans.
  ORPHAN_FLAG :=
else
  SELECTED_FILES := $(ALL_COMPOSE_FILES)
  ORPHAN_FLAG := --remove-orphans
endif

COMPOSE = docker compose --project-directory . $(foreach f,$(SELECTED_FILES),-f $(f))

.PHONY: build up down clean

build:
	docker build -t $(AIRFLOW_IMAGE) infra/docker/images/airflow

up:
	docker network create data-platform 2>/dev/null || true
	$(COMPOSE) up -d --build $(ORPHAN_FLAG)

down:
	$(COMPOSE) down $(ORPHAN_FLAG)

clean:
	docker image prune -f
