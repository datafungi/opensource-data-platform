POSTGRES_COMPOSE := docker/postgres/docker-compose.yaml
AIRFLOW_COMPOSE  := docker/airflow/docker-compose.yaml
MARQUEZ_COMPOSE  := docker/marquez/docker-compose.yaml
MINIO_COMPOSE    := docker/minio/docker-compose.yaml
AIRFLOW_IMAGE    := extended_airflow:3.1.7-python3.12

# Compose files per component (dependencies included)
COMPOSE_FILES_postgres := $(POSTGRES_COMPOSE)
COMPOSE_FILES_airflow  := $(POSTGRES_COMPOSE) $(AIRFLOW_COMPOSE)
COMPOSE_FILES_marquez  := $(POSTGRES_COMPOSE) $(MARQUEZ_COMPOSE)
COMPOSE_FILES_minio    := $(MINIO_COMPOSE)
ALL_COMPOSE_FILES      := $(POSTGRES_COMPOSE) $(AIRFLOW_COMPOSE) $(MARQUEZ_COMPOSE) $(MINIO_COMPOSE)

COMPONENT := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

ifneq ($(COMPONENT),)
  SELECTED_FILES := $(COMPOSE_FILES_$(COMPONENT))
  $(eval $(COMPONENT):;@:)
else
  SELECTED_FILES := $(ALL_COMPOSE_FILES)
endif

COMPOSE = docker compose --project-directory . $(foreach f,$(SELECTED_FILES),-f $(f))

.PHONY: build up down clean

build:
	docker build -t $(AIRFLOW_IMAGE) docker/airflow

up:
	docker network create data-platform 2>/dev/null || true
	$(COMPOSE) up -d --build --remove-orphans

down:
	$(COMPOSE) down --remove-orphans

clean:
	docker image prune -f
