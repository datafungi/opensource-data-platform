"""Daily backup DAG — dumps PostgreSQL and Redis to SeaweedFS object storage."""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

default_args = {
    "owner": "platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="backup_dag",
    description="Nightly PostgreSQL and Redis backups to SeaweedFS",
    schedule="@daily",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["platform", "backup"],
) as dag:

    # pg_dump → gzip → upload to s3://backups/postgres/YYYY-MM-DD.sql.gz
    backup_postgres = BashOperator(
        task_id="backup_postgres",
        bash_command="""
set -euo pipefail
DATE=$(date +%F)
DUMP_FILE="/tmp/postgres_${DATE}.sql.gz"

PGPASSWORD="{{ conn.postgres_default.password }}" \
  pg_dump \
  -h "{{ conn.postgres_default.host }}" \
  -p "{{ conn.postgres_default.port }}" \
  -U "{{ conn.postgres_default.login }}" \
  "{{ conn.postgres_default.schema }}" \
  | gzip > "$DUMP_FILE"

AWS_ACCESS_KEY_ID="{{ var.value.seaweedfs_access_key }}" \
AWS_SECRET_ACCESS_KEY="{{ var.value.seaweedfs_secret_key }}" \
  aws --endpoint-url "{{ var.value.seaweedfs_endpoint }}" \
  s3 cp "$DUMP_FILE" "s3://backups/postgres/${DATE}.sql.gz"

rm -f "$DUMP_FILE"
echo "PostgreSQL backup uploaded: backups/postgres/${DATE}.sql.gz"
""",
    )

    # Copy Redis RDB snapshot to s3://backups/redis/YYYY-MM-DD.rdb
    backup_redis = BashOperator(
        task_id="backup_redis",
        bash_command="""
set -euo pipefail
DATE=$(date +%F)
RDB_FILE="/tmp/redis_${DATE}.rdb"

redis-cli \
  -h "{{ conn.redis_default.host }}" \
  -p "{{ conn.redis_default.port }}" \
  --rdb "$RDB_FILE"

AWS_ACCESS_KEY_ID="{{ var.value.seaweedfs_access_key }}" \
AWS_SECRET_ACCESS_KEY="{{ var.value.seaweedfs_secret_key }}" \
  aws --endpoint-url "{{ var.value.seaweedfs_endpoint }}" \
  s3 cp "$RDB_FILE" "s3://backups/redis/${DATE}.rdb"

rm -f "$RDB_FILE"
echo "Redis backup uploaded: backups/redis/${DATE}.rdb"
""",
    )

    [backup_postgres, backup_redis]
