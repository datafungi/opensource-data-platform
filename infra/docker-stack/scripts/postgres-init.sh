#!/usr/bin/env bash
# Runs once on first boot (empty data dir). Creates application users and
# databases from passwords stored as Docker secrets.
set -euo pipefail

AIRFLOW_PASS=$(cat /run/secrets/postgres_airflow_password)
POLARIS_PASS=$(cat /run/secrets/postgres_polaris_password)

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-SQL
  CREATE USER airflow WITH PASSWORD '${AIRFLOW_PASS}';
  CREATE DATABASE airflow OWNER airflow;

  CREATE USER polaris WITH PASSWORD '${POLARIS_PASS}';
  CREATE DATABASE polaris OWNER polaris;
SQL
