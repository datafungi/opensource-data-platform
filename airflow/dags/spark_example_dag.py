"""Spark example DAG — reads from ClickHouse, writes Iceberg table to SeaweedFS."""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.apache.spark.operators.spark_submit import SparkSubmitOperator

default_args = {
    "owner": "platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

# Spark configuration for SeaweedFS (S3-compatible) and Iceberg
SPARK_CONF = {
    # Iceberg extensions
    "spark.sql.extensions": "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    "spark.sql.catalog.iceberg": "org.apache.iceberg.spark.SparkCatalog",
    "spark.sql.catalog.iceberg.type": "rest",
    "spark.sql.catalog.iceberg.uri": "http://polaris:8181",
    "spark.sql.catalog.iceberg.warehouse": "s3a://iceberg-warehouse",
    # SeaweedFS / S3A settings
    "spark.hadoop.fs.s3a.endpoint": "http://seaweedfs:8333",
    "spark.hadoop.fs.s3a.path.style.access": "true",
    "spark.hadoop.fs.s3a.impl": "org.apache.hadoop.fs.s3a.S3AFileSystem",
    "spark.hadoop.fs.s3a.aws.credentials.provider": "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider",
    # Credentials injected via Airflow Variables (resolved from Vault)
    "spark.hadoop.fs.s3a.access.key": "{{ var.value.seaweedfs_access_key }}",
    "spark.hadoop.fs.s3a.secret.key": "{{ var.value.seaweedfs_secret_key }}",
    # ClickHouse JDBC for reading source data
    "spark.jars.packages": "com.clickhouse:clickhouse-jdbc:0.6.0",
}

with DAG(
    dag_id="spark_iceberg_example",
    description="Read orders from ClickHouse, write as Iceberg table to SeaweedFS",
    schedule="@daily",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["spark", "iceberg", "seaweedfs"],
) as dag:

    transform_orders = SparkSubmitOperator(
        task_id="transform_orders_to_iceberg",
        application="/dags/repo/spark_jobs/orders_to_iceberg.py",
        conn_id="spark_default",
        conf=SPARK_CONF,
        application_args=[
            "--clickhouse-host", "clickhouse",
            "--clickhouse-port", "8123",
            "--output-table", "iceberg.default.orders_iceberg",
            "--execution-date", "{{ ds }}",
        ],
        name="orders_to_iceberg_{{ ds }}",
        verbose=True,
    )
