AIRFLOW_COMPOSE    := infra/dev/compose/airflow.lite.yaml
CLICKHOUSE_COMPOSE := infra/dev/compose/clickhouse.yaml
SEAWEEDFS_COMPOSE  := infra/dev/compose/seaweedfs.yaml
VAULT_COMPOSE      := infra/dev/compose/vault.yaml
TRINO_COMPOSE      := infra/dev/compose/trino.yaml
SPARK_COMPOSE      := infra/dev/compose/spark.yaml
KAFKA_COMPOSE      := infra/dev/compose/kafka.yaml
FLINK_COMPOSE      := infra/dev/compose/flink.yaml

AIRFLOW_IMAGE := localairflow:latest
DEV_NETWORK   := data-platform-dev

COMPOSE_FILES_airflow    := $(AIRFLOW_COMPOSE)
COMPOSE_FILES_clickhouse := $(CLICKHOUSE_COMPOSE)
COMPOSE_FILES_seaweedfs  := $(SEAWEEDFS_COMPOSE)
COMPOSE_FILES_vault      := $(VAULT_COMPOSE)
COMPOSE_FILES_trino      := $(TRINO_COMPOSE)
COMPOSE_FILES_spark      := $(SPARK_COMPOSE)
COMPOSE_FILES_kafka      := $(KAFKA_COMPOSE)
COMPOSE_FILES_flink      := $(KAFKA_COMPOSE) $(FLINK_COMPOSE)
ALL_COMPOSE_FILES        := $(AIRFLOW_COMPOSE) $(CLICKHOUSE_COMPOSE) $(SEAWEEDFS_COMPOSE) \
                            $(VAULT_COMPOSE) $(TRINO_COMPOSE) $(SPARK_COMPOSE)

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

.PHONY: build up down clean vault-init seaweedfs-init kafka-init

build:
	docker build -t $(AIRFLOW_IMAGE) -f infra/images/airflow.Dockerfile .

up:
	docker network create $(DEV_NETWORK) 2>/dev/null || true
	$(COMPOSE) up -d --build $(ORPHAN_FLAG)

down:
	$(COMPOSE) down $(ORPHAN_FLAG)

clean:
	docker image prune -f

# Bootstrap Vault dev instance with the secrets Airflow expects.
# Requires: make up vault (Vault must be running in dev mode, root token = "root")
vault-init:
	@echo "Seeding Vault dev instance..."
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault secrets enable -path=secret kv-v2 2>/dev/null || true
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/fernet-key \
	    value="$$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/api-secret-key value="$$(openssl rand -hex 32)"
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/sql-alchemy-conn \
	    value="postgresql+psycopg2://airflow:airflow@postgres:5432/airflow"
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/broker-url value="redis://:@redis:6379/0"
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/result-backend \
	    value="db+postgresql://airflow:airflow@postgres:5432/airflow"
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/connections/seaweedfs_logs \
	    value="aws://seaweedadmin:seaweedadmin@seaweedfs:8333?endpoint_url=http%3A%2F%2Fseaweedfs%3A8333&region_name=us-east-1"
	@echo "Vault seeded. Access at http://localhost:8200 (token: root)"

# Create required S3 buckets in SeaweedFS.
# Requires: make up seaweedfs (SeaweedFS must be running)
# Requires: aws CLI or mc (MinIO client) installed
seaweedfs-init:
	@echo "Creating SeaweedFS buckets..."
	@AWS_ACCESS_KEY_ID=$${SEAWEEDFS_ACCESS_KEY:-seaweedadmin} \
	  AWS_SECRET_ACCESS_KEY=$${SEAWEEDFS_SECRET_KEY:-seaweedadmin} \
	  aws --endpoint-url http://localhost:8333 s3 mb s3://airflow-logs      2>/dev/null || true
	@AWS_ACCESS_KEY_ID=$${SEAWEEDFS_ACCESS_KEY:-seaweedadmin} \
	  AWS_SECRET_ACCESS_KEY=$${SEAWEEDFS_SECRET_KEY:-seaweedadmin} \
	  aws --endpoint-url http://localhost:8333 s3 mb s3://backups           2>/dev/null || true
	@AWS_ACCESS_KEY_ID=$${SEAWEEDFS_ACCESS_KEY:-seaweedadmin} \
	  AWS_SECRET_ACCESS_KEY=$${SEAWEEDFS_SECRET_KEY:-seaweedadmin} \
	  aws --endpoint-url http://localhost:8333 s3 mb s3://iceberg-warehouse 2>/dev/null || true
	@echo "Buckets ready: airflow-logs, backups, iceberg-warehouse"

# Create default Kafka topics.
# Requires: make up kafka (Kafka must be running)
kafka-init:
	@echo "Creating Kafka topics..."
	@docker compose --project-directory . -f $(KAFKA_COMPOSE) exec kafka \
	  kafka-topics.sh --bootstrap-server localhost:9092 \
	    --create --if-not-exists --topic raw-orders       --partitions 3 --replication-factor 1
	@docker compose --project-directory . -f $(KAFKA_COMPOSE) exec kafka \
	  kafka-topics.sh --bootstrap-server localhost:9092 \
	    --create --if-not-exists --topic flink-output     --partitions 3 --replication-factor 1
	@echo "Topics ready: raw-orders, flink-output"
