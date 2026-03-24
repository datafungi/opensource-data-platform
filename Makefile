COMPOSE_FILE := docker/airflow/docker-compose.yaml
AIRFLOW_IMAGE := extended_airflow:3.1.7-python3.12

.PHONY: build up down clean

build:
	docker build -t $(AIRFLOW_IMAGE) docker/airflow

up:
	docker compose -f $(COMPOSE_FILE) up -d --build

down:
	docker compose -f $(COMPOSE_FILE) down --remove-orphans

clean:
	docker image prune -f
