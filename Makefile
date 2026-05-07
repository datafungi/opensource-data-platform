AIRFLOW_COMPOSE         := infra/dev/compose/airflow.lite.yaml
CLICKHOUSE_COMPOSE      := infra/dev/compose/clickhouse.yaml
SEAWEEDFS_COMPOSE       := infra/dev/compose/seaweedfs.yaml
HASHICORP_VAULT_COMPOSE := infra/dev/compose/hashicorp-vault.yaml
OPENBAO_COMPOSE         := infra/dev/compose/openbao.yaml
TRINO_COMPOSE           := infra/dev/compose/trino.yaml
RANGER_COMPOSE          := infra/dev/compose/ranger.yaml
POLARIS_COMPOSE         := infra/dev/compose/polaris.yaml
SPARK_COMPOSE           := infra/dev/compose/spark.yaml
KAFKA_COMPOSE           := infra/dev/compose/kafka.yaml
FLINK_COMPOSE           := infra/dev/compose/flink.yaml
ENV_FILE                := $(if $(wildcard .env),--env-file .env,)

AIRFLOW_IMAGE := localairflow:latest
DEV_NETWORK   := data-platform-dev

COMPOSE_FILES_airflow    := $(AIRFLOW_COMPOSE)
COMPOSE_FILES_clickhouse := $(CLICKHOUSE_COMPOSE)
COMPOSE_FILES_seaweedfs  := $(SEAWEEDFS_COMPOSE)
# vault and openbao are mutually exclusive — both bind port 8200. Use one or the other.
COMPOSE_FILES_vault      := $(HASHICORP_VAULT_COMPOSE)
COMPOSE_FILES_openbao    := $(OPENBAO_COMPOSE)
COMPOSE_FILES_trino      := $(RANGER_COMPOSE) $(POLARIS_COMPOSE) $(TRINO_COMPOSE)
COMPOSE_FILES_ranger     := $(RANGER_COMPOSE)
COMPOSE_FILES_polaris    := $(POLARIS_COMPOSE)
COMPOSE_FILES_spark      := $(SPARK_COMPOSE)
COMPOSE_FILES_kafka      := $(KAFKA_COMPOSE)
COMPOSE_FILES_flink      := $(KAFKA_COMPOSE) $(FLINK_COMPOSE)
# ALL uses OpenBao as the default secrets manager. Swap for $(HASHICORP_VAULT_COMPOSE) if preferred.
ALL_COMPOSE_FILES        := $(AIRFLOW_COMPOSE) $(CLICKHOUSE_COMPOSE) $(SEAWEEDFS_COMPOSE) \
                            $(OPENBAO_COMPOSE) $(RANGER_COMPOSE) $(POLARIS_COMPOSE) \
                            $(TRINO_COMPOSE) $(SPARK_COMPOSE)

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

COMPOSE = docker compose --project-directory . $(ENV_FILE) $(foreach f,$(SELECTED_FILES),-f $(f))

.PHONY: build up down clean vault-init openbao-init seaweedfs-init kafka-init ranger-init polaris-init openldap-init

build:
	docker build -t $(AIRFLOW_IMAGE) -f infra/images/airflow.Dockerfile .

up:
	docker network create $(DEV_NETWORK) 2>/dev/null || true
	$(COMPOSE) up -d --build $(ORPHAN_FLAG)

down:
	$(COMPOSE) down $(ORPHAN_FLAG)

clean:
	docker image prune -f

# Bootstrap HashiCorp Vault dev instance with the secrets Airflow expects.
# Requires: make up vault (Vault must be running in dev mode, root token = "root")
vault-init:
	@echo "Seeding HashiCorp Vault dev instance..."
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault secrets enable -path=secret kv-v2 2>/dev/null || true
	@VAULT_ADDR=http://localhost:8200 VAULT_TOKEN=root \
	  vault kv put secret/airflow/config/fernet-key \
	    value="$$(python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
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
	@echo "HashiCorp Vault seeded. Access at http://localhost:8200 (token: root)"

# Bootstrap OpenBao dev instance with the secrets Airflow expects.
# Requires: make up openbao (OpenBao must be running in dev mode, root token = "root")
# Runs bao inside the container — no host bao install needed.
OPENBAO_EXEC = docker compose --project-directory . $(ENV_FILE) -f $(OPENBAO_COMPOSE) exec -T -e VAULT_TOKEN=root openbao bao
openbao-init:
	@echo "Seeding OpenBao dev instance..."
	@$(OPENBAO_EXEC) secrets enable -path=secret kv-v2 2>/dev/null || true
	@$(OPENBAO_EXEC) kv put secret/airflow/config/fernet-key \
	    value="$$(python3 -c 'import base64,os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
	@$(OPENBAO_EXEC) kv put secret/airflow/config/api-secret-key \
	    value="$$(openssl rand -hex 32)"
	@$(OPENBAO_EXEC) kv put secret/airflow/config/sql-alchemy-conn \
	    value="postgresql+psycopg2://airflow:airflow@postgres:5432/airflow"
	@$(OPENBAO_EXEC) kv put secret/airflow/config/broker-url \
	    value="redis://:@redis:6379/0"
	@$(OPENBAO_EXEC) kv put secret/airflow/config/result-backend \
	    value="db+postgresql://airflow:airflow@postgres:5432/airflow"
	@$(OPENBAO_EXEC) kv put secret/airflow/connections/seaweedfs_logs \
	    value="aws://seaweedadmin:seaweedadmin@seaweedfs:8333?endpoint_url=http%3A%2F%2Fseaweedfs%3A8333&region_name=us-east-1"
	@echo "OpenBao seeded. Access at http://localhost:8200 (token: root)"

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

# Register the Trino service in Ranger Admin so the Ranger plugin can fetch policies.
# Requires: make up trino (ranger-admin must be healthy at http://localhost:6080)
# The service name must match ranger.service.name in access-control.properties.
RANGER_ADMIN_URL   ?= http://localhost:6080
RANGER_ADMIN_USER  ?= admin
RANGER_ADMIN_PASS  ?= rangerR0cks!
ranger-init:
	@echo "Registering Trino service in Ranger Admin..."
	@curl -sf -u "$(RANGER_ADMIN_USER):$(RANGER_ADMIN_PASS)" \
	  -X POST "$(RANGER_ADMIN_URL)/service/plugins/services" \
	  -H "Content-Type: application/json" \
	  -d '{ \
	    "name": "trino_dev", \
	    "type": "trino", \
	    "description": "Trino dev cluster", \
	    "isEnabled": true, \
	    "configs": { \
	      "username": "admin", \
	      "password": "admin", \
	      "jdbc.url": "jdbc:trino://trino:8443/", \
	      "jdbc.driverClassName": "io.trino.jdbc.TrinoDriver" \
	    } \
	  }' 2>/dev/null || true
	@echo "Ranger trino_dev service registered. Define policies at http://localhost:6080"

# Bootstrap the Polaris REST catalog: create the 'warehouse' catalog and grant the
# root principal full access. Requires: make up trino (polaris must be healthy).
# Also requires: make seaweedfs-init (bucket s3://iceberg-warehouse must exist).
polaris-init:
	@set -e; \
	POLARIS_URL=$${POLARIS_ADMIN_URL:-http://localhost:8181}; \
	CLIENT_ID=$${POLARIS_BOOTSTRAP_CLIENT_ID:-root}; \
	CLIENT_SECRET=$${POLARIS_BOOTSTRAP_CLIENT_SECRET:-s3cr3t}; \
	echo "Bootstrapping Polaris catalog..."; \
	TOKEN=$$(curl -sf -X POST "$$POLARIS_URL/api/catalog/v1/oauth/tokens" \
	  -H "Content-Type: application/x-www-form-urlencoded" \
	  -d "grant_type=client_credentials&client_id=$$CLIENT_ID&client_secret=$$CLIENT_SECRET&scope=PRINCIPAL_ROLE:ALL" \
	  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"); \
	echo "  Creating 'warehouse' catalog..."; \
	curl -sf -X POST "$$POLARIS_URL/api/management/v1/catalogs" \
	  -H "Authorization: Bearer $$TOKEN" \
	  -H "Content-Type: application/json" \
	  -d '{"catalog":{"name":"warehouse","type":"INTERNAL","properties":{"default-base-location":"s3://iceberg-warehouse"},"storageConfigInfo":{"storageType":"S3","allowedLocations":["s3://iceberg-warehouse"],"roleArn":"arn:aws:iam::000000000000:role/dev"}}}' || true; \
	echo "  Creating catalog role 'warehouse_admin'..."; \
	curl -sf -X POST "$$POLARIS_URL/api/management/v1/catalogs/warehouse/catalog-roles" \
	  -H "Authorization: Bearer $$TOKEN" \
	  -H "Content-Type: application/json" \
	  -d '{"catalogRole":{"name":"warehouse_admin"}}' || true; \
	echo "  Granting CATALOG_MANAGE_CONTENT to warehouse_admin..."; \
	curl -sf -X PUT "$$POLARIS_URL/api/management/v1/catalogs/warehouse/catalog-roles/warehouse_admin/grants" \
	  -H "Authorization: Bearer $$TOKEN" \
	  -H "Content-Type: application/json" \
	  -d '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}' || true; \
	echo "  Creating principal role 'admin_role'..."; \
	curl -sf -X POST "$$POLARIS_URL/api/management/v1/principal-roles" \
	  -H "Authorization: Bearer $$TOKEN" \
	  -H "Content-Type: application/json" \
	  -d '{"principalRole":{"name":"admin_role"}}' || true; \
	echo "  Assigning warehouse_admin to admin_role..."; \
	curl -sf -X PUT "$$POLARIS_URL/api/management/v1/catalogs/warehouse/principal-roles/admin_role/catalog-roles/warehouse_admin" \
	  -H "Authorization: Bearer $$TOKEN" || true; \
	echo "  Assigning admin_role to root principal..."; \
	curl -sf -X PUT "$$POLARIS_URL/api/management/v1/principals/root/principal-roles/admin_role" \
	  -H "Authorization: Bearer $$TOKEN" || true; \
	echo "Polaris warehouse catalog ready. Trino can now use the 'iceberg' connector."

# Enable the OpenLDAP memberOf overlay so that user entries carry memberOf back-references.
# Run ONCE after first `make up trino`. Idempotent (-c ignores already-exists errors).
# Requires: make up trino (openldap must be running)
MEMBEROF_LDIF := dn: cn=module,cn=config\nchangetype: add\nobjectClass: olcModuleList\ncn: module\nolcModulepath: /usr/lib/ldap\nolcModuleload: memberof\n\ndn: olcOverlay=memberof,olcDatabase={1}mdb,cn=config\nchangetype: add\nobjectClass: olcOverlayConfig\nobjectClass: olcMemberOf\nolcOverlay: memberof\nolcMemberOfRefInt: TRUE\nolcMemberOfGroupOC: groupOfNames\nolcMemberOfMemberAD: member\nolcMemberOfMemberOfAD: memberOf
openldap-init:
	@echo "Enabling memberOf overlay in OpenLDAP..."
	@printf '$(MEMBEROF_LDIF)\n' | \
	  docker compose --project-directory . $(ENV_FILE) -f $(RANGER_COMPOSE) \
	  exec -T openldap ldapmodify -Y EXTERNAL -H ldapi:/// -c || true
	@echo "Done. Restart openldap or re-add group entries to populate memberOf back-references."

# Create default Kafka topics.
# Requires: make up kafka (Kafka must be running)
kafka-init:
	@echo "Creating Kafka topics..."
	@docker compose --project-directory . $(ENV_FILE) -f $(KAFKA_COMPOSE) exec kafka \
	  kafka-topics.sh --bootstrap-server localhost:9092 \
	    --create --if-not-exists --topic raw-orders       --partitions 3 --replication-factor 1
	@docker compose --project-directory . $(ENV_FILE) -f $(KAFKA_COMPOSE) exec kafka \
	  kafka-topics.sh --bootstrap-server localhost:9092 \
	    --create --if-not-exists --topic flink-output     --partitions 3 --replication-factor 1
	@echo "Topics ready: raw-orders, flink-output"
