AIRFLOW_COMPOSE    := infra/dev/compose/airflow.lite.yaml
MSSQL_COMPOSE      := infra/dev/compose/mssql.yaml
CLICKHOUSE_COMPOSE := infra/dev/compose/clickhouse.yaml
RUSTFS_COMPOSE     := infra/dev/compose/rustfs.yaml
SEAWEEDFS_COMPOSE  := infra/dev/compose/seaweedfs.yaml

AIRFLOW_IMAGE      := localairflow:latest
DEV_NETWORK        := data-platform-dev

COMPOSE_FILES_airflow    := $(AIRFLOW_COMPOSE)
COMPOSE_FILES_mssql      := $(MSSQL_COMPOSE)
COMPOSE_FILES_clickhouse := $(CLICKHOUSE_COMPOSE)
COMPOSE_FILES_rustfs     := $(RUSTFS_COMPOSE)
COMPOSE_FILES_seaweedfs  := $(SEAWEEDFS_COMPOSE)
ALL_COMPOSE_FILES        := $(AIRFLOW_COMPOSE) $(MSSQL_COMPOSE) $(CLICKHOUSE_COMPOSE) $(RUSTFS_COMPOSE) $(SEAWEEDFS_COMPOSE)

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
  SELECTED_FILES := $(foreach c,$(COMPONENT),$(COMPOSE_FILES_$(c)))
  # Don't remove orphans for single-component deploys — other components are not orphans.
  ORPHAN_FLAG :=
else
  SELECTED_FILES := $(ALL_COMPOSE_FILES)
  ORPHAN_FLAG    := --remove-orphans
endif

COMPOSE = docker compose --project-directory . $(foreach f,$(SELECTED_FILES),-f $(f))

.PHONY: build up down clean

build:
	docker build -t $(AIRFLOW_IMAGE) -f infra/images/airflow.Dockerfile .

up:
	docker network create $(DEV_NETWORK) 2>/dev/null || true
	$(COMPOSE) up -d --build $(ORPHAN_FLAG)

down:
	$(COMPOSE) down $(ORPHAN_FLAG)

clean:
	docker image prune -f
