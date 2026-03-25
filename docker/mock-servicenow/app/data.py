"""
Seeded data generation for mock ServiceNow tables.

Records are generated via DuckDB SQL (generate_series + random()) and persisted
to a DuckDB file so the expensive pass runs only once.  Subsequent startups skip
generation and query the existing file directly.

Using DuckDB SQL instead of Python row-by-row generation gives ~100x throughput
because DuckDB executes the INSERT in a vectorised, multi-threaded manner.

Supported tables
----------------
- incident
- problem
- change_request
- sys_user
- cmdb_ci
"""

from __future__ import annotations

import logging
import os
import threading
from pathlib import Path

import duckdb

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------

DB_PATH = Path(os.getenv("MOCK_SN_DB_PATH", "/data/mock_servicenow.duckdb"))
TOTAL_RECORDS: int = int(os.getenv("MOCK_SN_TOTAL_RECORDS", "1000000"))
# MOCK_SN_SEED can be any integer; normalized to [-1, 1] for DuckDB's setseed().
_raw_seed: int = int(os.getenv("MOCK_SN_SEED", "42"))
SEED: float = (_raw_seed % 200 - 100) / 100  # maps any int → [-1.0, 1.0)

# Set once initialise_database() completes; used by routes to gate queries.
DB_READY = threading.Event()

# ---------------------------------------------------------------------------
# Table schemas
# ---------------------------------------------------------------------------

TABLE_SCHEMAS: dict[str, str] = {
    "incident": """
        CREATE TABLE IF NOT EXISTS incident (
            sys_id            VARCHAR PRIMARY KEY,
            number            VARCHAR,
            short_description VARCHAR,
            description       VARCHAR,
            state             VARCHAR,
            priority          VARCHAR,
            impact            VARCHAR,
            urgency           VARCHAR,
            category          VARCHAR,
            subcategory       VARCHAR,
            caller_id         VARCHAR,
            assigned_to       VARCHAR,
            assignment_group  VARCHAR,
            cmdb_ci           VARCHAR,
            opened_at         TIMESTAMP,
            resolved_at       TIMESTAMP,
            sys_created_on    TIMESTAMP,
            sys_updated_on    TIMESTAMP,
            close_notes       VARCHAR
        )
    """,
    "problem": """
        CREATE TABLE IF NOT EXISTS problem (
            sys_id            VARCHAR PRIMARY KEY,
            number            VARCHAR,
            short_description VARCHAR,
            description       VARCHAR,
            state             VARCHAR,
            priority          VARCHAR,
            impact            VARCHAR,
            category          VARCHAR,
            assigned_to       VARCHAR,
            assignment_group  VARCHAR,
            known_error       VARCHAR,
            workaround        VARCHAR,
            opened_at         TIMESTAMP,
            resolved_at       TIMESTAMP,
            sys_created_on    TIMESTAMP,
            sys_updated_on    TIMESTAMP
        )
    """,
    "change_request": """
        CREATE TABLE IF NOT EXISTS change_request (
            sys_id            VARCHAR PRIMARY KEY,
            number            VARCHAR,
            short_description VARCHAR,
            description       VARCHAR,
            state             VARCHAR,
            type              VARCHAR,
            priority          VARCHAR,
            risk              VARCHAR,
            impact            VARCHAR,
            category          VARCHAR,
            assigned_to       VARCHAR,
            assignment_group  VARCHAR,
            start_date        TIMESTAMP,
            end_date          TIMESTAMP,
            sys_created_on    TIMESTAMP,
            sys_updated_on    TIMESTAMP
        )
    """,
    "sys_user": """
        CREATE TABLE IF NOT EXISTS sys_user (
            sys_id         VARCHAR PRIMARY KEY,
            user_name      VARCHAR,
            first_name     VARCHAR,
            last_name      VARCHAR,
            email          VARCHAR,
            department     VARCHAR,
            title          VARCHAR,
            phone          VARCHAR,
            active         VARCHAR,
            sys_created_on TIMESTAMP,
            sys_updated_on TIMESTAMP
        )
    """,
    "cmdb_ci": """
        CREATE TABLE IF NOT EXISTS cmdb_ci (
            sys_id             VARCHAR PRIMARY KEY,
            name               VARCHAR,
            class_name         VARCHAR,
            ip_address         VARCHAR,
            os                 VARCHAR,
            manufacturer       VARCHAR,
            model_id           VARCHAR,
            serial_number      VARCHAR,
            install_status     VARCHAR,
            operational_status VARCHAR,
            sys_created_on     TIMESTAMP,
            sys_updated_on     TIMESTAMP
        )
    """,
}

# ---------------------------------------------------------------------------
# SQL generation statements (one per table)
# Approach: generate_series produces the row index; random() picks from arrays.
# floor(random() * N) gives integers [0, N-1]; +1 shifts to 1-based list index.
# md5(i::varchar) produces a deterministic-looking 32-char hex string for sys_id.
# ---------------------------------------------------------------------------

_NAMES_SQL = (
    "['James Smith','Mary Johnson','John Williams','Patricia Brown','Robert Jones',"
    " 'Jennifer Garcia','Michael Miller','Linda Davis','William Rodriguez','Barbara Martinez',"
    " 'David Hernandez','Susan Lopez','Richard Gonzalez','Jessica Wilson','Joseph Anderson',"
    " 'Sarah Thomas','Thomas Taylor','Karen Moore','Charles Jackson','Lisa Martin']"
)
_COMPANIES_SQL = (
    "['Acme Corp','Global Tech','Pinnacle Systems','Apex Solutions','Nexus IT',"
    " 'Vertex Networks','Horizon Services','Summit Technology','Zenith Digital','Atlas Computing']"
)
_SHORT_DESCS_SQL = (
    "['Unable to access server after recent change','High CPU utilisation detected',"
    " 'Disk space critical on host','Network connectivity lost','Application crash reported',"
    " 'Authentication failure for users','Slow response time reported','Service restart required',"
    " 'Backup job failed','Security alert triggered','Memory leak detected',"
    " 'Certificate expiry warning']"
)

_TABLE_SQL: dict[str, str] = {
    "incident": """
        SELECT setseed({seed});
        INSERT INTO incident
        SELECT
            md5(i::varchar)                                                          AS sys_id,
            printf('INC%010d', i)                                                    AS number,
            {short_descs}[1 + (floor(random() * 12))::integer]                      AS short_description,
            'Issue reported. Assigned for investigation and resolution.'             AS description,
            ['1','2','3','4','5','6','7'][1 + (floor(random() * 7))::integer]        AS state,
            ['1','2','3','4','5'][1 + (floor(random() * 5))::integer]                AS priority,
            ['1','2','3'][1 + (floor(random() * 3))::integer]                        AS impact,
            ['1','2','3'][1 + (floor(random() * 3))::integer]                        AS urgency,
            ['network','hardware','software','database','security','inquiry','facilities']
                [1 + (floor(random() * 7))::integer]                                AS category,
            ['connectivity','performance','failure','configuration','access','other']
                [1 + (floor(random() * 6))::integer]                                AS subcategory,
            {names}[1 + (floor(random() * 20))::integer]                            AS caller_id,
            {names}[1 + (floor(random() * 20))::integer]                            AS assigned_to,
            {companies}[1 + (floor(random() * 10))::integer]                        AS assignment_group,
            printf('srv-%04d', 1 + (floor(random() * 500))::integer)                AS cmdb_ci,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS opened_at,
            CASE WHEN random() > 0.3
                THEN timestamp '2023-06-01' + to_seconds((random() * 31536000)::bigint)
                ELSE NULL END                                                        AS resolved_at,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS sys_created_on,
            timestamp '2024-01-01' + to_seconds((random() * 31536000)::bigint)      AS sys_updated_on,
            CASE WHEN random() > 0.3 THEN 'Issue resolved successfully.' ELSE NULL END AS close_notes
        FROM generate_series(0, {total} - 1) t(i);
    """,
    "problem": """
        SELECT setseed({seed});
        INSERT INTO problem
        SELECT
            md5('prb' || i::varchar)                                                 AS sys_id,
            printf('PRB%010d', i)                                                    AS number,
            {short_descs}[1 + (floor(random() * 12))::integer]                      AS short_description,
            'Root cause investigation in progress.'                                  AS description,
            ['1','2','3','4','5','6','7'][1 + (floor(random() * 7))::integer]        AS state,
            ['1','2','3','4','5'][1 + (floor(random() * 5))::integer]                AS priority,
            ['1','2','3'][1 + (floor(random() * 3))::integer]                        AS impact,
            ['network','hardware','software','database','security','inquiry','facilities']
                [1 + (floor(random() * 7))::integer]                                AS category,
            {names}[1 + (floor(random() * 20))::integer]                            AS assigned_to,
            {companies}[1 + (floor(random() * 10))::integer]                        AS assignment_group,
            ['true','false'][1 + (floor(random() * 2))::integer]                    AS known_error,
            CASE WHEN random() > 0.5 THEN 'Apply patch and restart service.' ELSE NULL END AS workaround,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS opened_at,
            CASE WHEN random() > 0.5
                THEN timestamp '2023-06-01' + to_seconds((random() * 31536000)::bigint)
                ELSE NULL END                                                        AS resolved_at,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS sys_created_on,
            timestamp '2024-01-01' + to_seconds((random() * 31536000)::bigint)      AS sys_updated_on
        FROM generate_series(0, {total} - 1) t(i);
    """,
    "change_request": """
        SELECT setseed({seed});
        INSERT INTO change_request
        SELECT
            md5('chg' || i::varchar)                                                 AS sys_id,
            printf('CHG%010d', i)                                                    AS number,
            {short_descs}[1 + (floor(random() * 12))::integer]                      AS short_description,
            'Change implementation plan documented and approved.'                    AS description,
            ['draft','assess','authorize','scheduled','implement','review','closed']
                [1 + (floor(random() * 7))::integer]                                AS state,
            ['normal','standard','emergency'][1 + (floor(random() * 3))::integer]    AS type,
            ['1','2','3','4','5'][1 + (floor(random() * 5))::integer]                AS priority,
            ['high','moderate','low'][1 + (floor(random() * 3))::integer]            AS risk,
            ['1','2','3'][1 + (floor(random() * 3))::integer]                        AS impact,
            ['network','hardware','software','database','security','inquiry','facilities']
                [1 + (floor(random() * 7))::integer]                                AS category,
            {names}[1 + (floor(random() * 20))::integer]                            AS assigned_to,
            {companies}[1 + (floor(random() * 10))::integer]                        AS assignment_group,
            timestamp '2024-01-01' + to_seconds((random() * 31536000)::bigint)      AS start_date,
            timestamp '2024-01-01' + to_seconds((random() * 31536000 + 14400)::bigint) AS end_date,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS sys_created_on,
            timestamp '2024-01-01' + to_seconds((random() * 31536000)::bigint)      AS sys_updated_on
        FROM generate_series(0, {total} - 1) t(i);
    """,
    "sys_user": """
        SELECT setseed({seed});
        INSERT INTO sys_user
        SELECT
            md5('usr' || i::varchar)                                                 AS sys_id,
            lower(split_part({names}[1 + (floor(random() * 20))::integer], ' ', 1))
                || i::varchar                                                        AS user_name,
            split_part({names}[1 + (floor(random() * 20))::integer], ' ', 1)        AS first_name,
            split_part({names}[1 + (floor(random() * 20))::integer], ' ', 2)        AS last_name,
            lower(split_part({names}[1 + (floor(random() * 20))::integer], ' ', 1))
                || i::varchar || '@company.example'                                  AS email,
            ['IT Operations','Network Engineering','Security','Database Administration',
             'Application Support','Infrastructure','DevOps','Service Desk','Cloud Services',
             'Data Center'][1 + (floor(random() * 10))::integer]                    AS department,
            ['Systems Administrator','Network Engineer','Software Developer','DBA',
             'Security Analyst','Cloud Architect','DevOps Engineer','IT Manager',
             'Support Specialist','Infrastructure Engineer']
                [1 + (floor(random() * 10))::integer]                               AS title,
            printf('+1-%03d-%03d-%04d',
                100 + (floor(random() * 900))::integer,
                100 + (floor(random() * 900))::integer,
                1000 + (floor(random() * 9000))::integer)                           AS phone,
            ['true','false'][1 + (floor(random() * 2))::integer]                    AS active,
            timestamp '2020-01-01' + to_seconds((random() * 157680000)::bigint)     AS sys_created_on,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS sys_updated_on
        FROM generate_series(0, {total} - 1) t(i);
    """,
    "cmdb_ci": """
        SELECT setseed({seed});
        INSERT INTO cmdb_ci
        SELECT
            md5('ci' || i::varchar)                                                  AS sys_id,
            printf('srv-%04d.company.example', 1 + (floor(random() * 9999))::integer) AS name,
            ['cmdb_ci_server','cmdb_ci_computer','cmdb_ci_netgear',
             'cmdb_ci_database','cmdb_ci_app_server']
                [1 + (floor(random() * 5))::integer]                                AS class_name,
            printf('10.%d.%d.%d',
                (floor(random() * 256))::integer,
                (floor(random() * 256))::integer,
                1 + (floor(random() * 253))::integer)                               AS ip_address,
            ['Windows Server 2019','Windows Server 2022','RHEL 8','RHEL 9',
             'Ubuntu 22.04','Ubuntu 24.04','CentOS 7','Debian 12']
                [1 + (floor(random() * 8))::integer]                                AS os,
            ['Dell','HP','Lenovo','Cisco','IBM','Supermicro','Fujitsu']
                [1 + (floor(random() * 7))::integer]                                AS manufacturer,
            printf('MODEL-%04d', 1000 + (floor(random() * 9000))::integer)          AS model_id,
            printf('SN%09d', 100000000 + (floor(random() * 900000000))::integer)    AS serial_number,
            ['1','2','3','6','7'][1 + (floor(random() * 5))::integer]                AS install_status,
            ['1','2'][1 + (floor(random() * 2))::integer]                            AS operational_status,
            timestamp '2020-01-01' + to_seconds((random() * 157680000)::bigint)     AS sys_created_on,
            timestamp '2023-01-01' + to_seconds((random() * 63072000)::bigint)      AS sys_updated_on
        FROM generate_series(0, {total} - 1) t(i);
    """,
}

# ---------------------------------------------------------------------------
# DuckDB initialisation and data generation
# ---------------------------------------------------------------------------


def _table_is_populated(con: duckdb.DuckDBPyConnection, table: str) -> bool:
    count = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]  # noqa: S608
    return count >= TOTAL_RECORDS


def initialise_database() -> None:
    """Create tables and populate them if needed. Safe to call on every startup."""
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH))

    for table, ddl in TABLE_SCHEMAS.items():
        con.execute(ddl)

    for table, sql_template in _TABLE_SQL.items():
        if _table_is_populated(con, table):
            logger.info("Table %s already has %d records — skipping generation.", table, TOTAL_RECORDS)
            continue

        con.execute(f"DELETE FROM {table}")  # noqa: S608
        logger.info("Generating %d records for table '%s' via SQL …", TOTAL_RECORDS, table)

        sql = sql_template.format(
            seed=SEED,
            total=TOTAL_RECORDS,
            names=_NAMES_SQL,
            companies=_COMPANIES_SQL,
            short_descs=_SHORT_DESCS_SQL,
        )
        for statement in sql.strip().split(";"):
            stmt = statement.strip()
            if stmt:
                con.execute(stmt)

        logger.info("Table '%s' populated with %d records.", table, TOTAL_RECORDS)

    con.close()
    DB_READY.set()
    logger.info("Database initialisation complete — service is ready.")


# ---------------------------------------------------------------------------
# Query interface
# ---------------------------------------------------------------------------


def query_table(
    table: str,
    *,
    limit: int = 10,
    offset: int = 0,
    fields: list[str] | None = None,
    filters: list[tuple[str, str]] | None = None,
) -> list[dict]:
    """Return records from *table* applying pagination, field projection, and equality filters."""
    if table not in TABLE_SCHEMAS:
        return []

    con = duckdb.connect(str(DB_PATH), read_only=True)

    col_clause = ", ".join(fields) if fields else "*"
    where_clause = ""
    params: list[str] = []
    if filters:
        conditions = " AND ".join(f"{col} = ?" for col, _ in filters)
        where_clause = f"WHERE {conditions}"
        params = [val for _, val in filters]

    sql = (
        f"SELECT {col_clause} FROM {table} {where_clause} "  # noqa: S608
        f"LIMIT {limit} OFFSET {offset}"
    )
    result = con.execute(sql, params)
    columns = [desc[0] for desc in result.description]
    rows = [dict(zip(columns, row)) for row in result.fetchall()]
    con.close()
    return rows
