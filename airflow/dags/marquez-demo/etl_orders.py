from datetime import datetime

from airflow import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

with DAG(
    dag_id="etl_orders",
    schedule="@daily",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    tags=["marquez-demo"],
):
    SQLExecuteQueryOperator(
        task_id="ingest_raw_orders",
        conn_id="sqlite_default",
        sql=[
            "DROP TABLE IF EXISTS raw_orders",
            """
            CREATE TABLE raw_orders AS
            SELECT 1 AS order_id, 'Alice' AS customer, 120.50 AS amount, '2025-01-01' AS order_date
            UNION ALL SELECT 2, 'Bob', 89.00, '2025-01-01'
            UNION ALL SELECT 3, 'Charlie', 340.75, '2025-01-01'
            """,
        ],
    ) >> SQLExecuteQueryOperator(
        task_id="transform_orders",
        conn_id="sqlite_default",
        sql=[
            "DROP TABLE IF EXISTS transformed_orders",
            """
            CREATE TABLE transformed_orders AS
            SELECT order_id, customer, amount, ROUND(amount * 0.92, 2) AS amount_eur, order_date
            FROM raw_orders
            """,
        ],
    ) >> SQLExecuteQueryOperator(
        task_id="load_orders_report",
        conn_id="sqlite_default",
        sql=[
            "DROP TABLE IF EXISTS orders_report",
            """
            CREATE TABLE orders_report AS
            SELECT order_date, COUNT(*) AS total_orders, ROUND(SUM(amount_eur), 2) AS total_revenue_eur
            FROM transformed_orders
            GROUP BY order_date
            """,
        ],
    )
