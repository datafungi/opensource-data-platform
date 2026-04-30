"""dbt transformation DAG — orchestrates dbt models via astronomer-cosmos."""

from datetime import datetime, timedelta
from pathlib import Path

from cosmos import DbtDag, ProjectConfig, RenderConfig
from cosmos.config import ProfileConfig
from cosmos.profiles import ClickhouseUserPasswordProfileMapping

DBT_DIR = Path("/dags/repo/dbt")

profile_config = ProfileConfig(
    profile_name="data_platform",
    target_name="prod",
    profile_mapping=ClickhouseUserPasswordProfileMapping(
        conn_id="clickhouse_default",
        profile_args={"schema": "marts"},
    ),
)

dbt_clickhouse_dag = DbtDag(
    dag_id="dbt_clickhouse",
    description="Run dbt models against ClickHouse (staging → intermediate → marts)",
    project_config=ProjectConfig(dbt_project_path=DBT_DIR),
    profile_config=profile_config,
    render_config=RenderConfig(select=["staging+"]),
    schedule="@daily",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    default_args={
        "owner": "platform",
        "retries": 1,
        "retry_delay": timedelta(minutes=5),
    },
    tags=["dbt", "clickhouse", "transform"],
)
