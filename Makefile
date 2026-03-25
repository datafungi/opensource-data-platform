POSTGRES_COMPOSE_FILE := docker/postgres/docker-compose.yaml
AIRFLOW_COMPOSE_FILE := docker/airflow/docker-compose.yaml
AIRFLOW_IMAGE := extended_airflow:3.1.7-python3.12
COMPOSE := docker compose --project-directory . -f $(POSTGRES_COMPOSE_FILE) -f $(AIRFLOW_COMPOSE_FILE)

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
