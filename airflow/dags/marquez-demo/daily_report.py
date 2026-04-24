from datetime import datetime

from airflow import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

with DAG(
    dag_id="daily_report",
    schedule="@daily",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    tags=["marquez-demo"],
):
    SQLExecuteQueryOperator(
        task_id="generate_summary",
        conn_id="sqlite_default",
        sql=[
            "DROP TABLE IF EXISTS daily_summary",
            """
            CREATE TABLE daily_summary AS
            SELECT order_date, total_orders, total_revenue_eur
            FROM orders_report
            """,
        ],
    ) >> SQLExecuteQueryOperator(
        task_id="top_customers",
        conn_id="sqlite_default",
        sql="""
            SELECT customer, amount_eur
            FROM transformed_orders
            ORDER BY amount_eur DESC
        """,
    )
