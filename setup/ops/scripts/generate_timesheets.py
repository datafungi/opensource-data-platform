from __future__ import annotations

import csv
import random
from datetime import date, timedelta
from pathlib import Path

import duckdb

SEED = 42
MIN_BILLABLE_RATIO = 0.80
MAX_BILLABLE_RATIO = 0.90

OPS_DATA_DIR = Path(__file__).parent.parent / "data"

OUTPUT_FIELDS = [
    "timesheet_id",
    "allocation_id",
    "project_id",
    "employee_id",
    "work_date",
    "hours",
    "billable_hours",
    "internal_hours",
]


def _load_allocations(con: duckdb.DuckDBPyConnection, alloc_path: str) -> list[dict]:
    sql = f"""
        SELECT
            CAST(allocation_id AS INTEGER)  AS allocation_id,
            CAST(project_id AS INTEGER)     AS project_id,
            CAST(employee_id AS INTEGER)    AS employee_id,
            CAST(start_date AS DATE)        AS start_date,
            CAST(end_date AS DATE)          AS end_date,
            CAST(allocation_pct AS INTEGER) AS allocation_pct
        FROM read_csv_auto('{alloc_path}')
        ORDER BY allocation_id
    """
    cur = con.execute(sql)
    columns = [desc[0] for desc in cur.description]
    return [dict(zip(columns, row)) for row in cur.fetchall()]


def _working_days(start: date, end: date) -> list[date]:
    result = []
    current = start
    while current <= end:
        if current.weekday() < 5:
            result.append(current)
        current += timedelta(days=1)
    return result


def main() -> None:
    alloc_path = OPS_DATA_DIR / "ops_resource_allocations.csv"
    if not alloc_path.exists():
        print(f"ERROR: Required upstream file not found: {alloc_path}")
        raise SystemExit(1)

    con = duckdb.connect(":memory:")
    allocations = _load_allocations(con, str(alloc_path))

    random.seed(SEED)

    timesheet_id = 1
    rows: list[dict] = []

    for allocation in allocations:
        hours = round(8 * (allocation["allocation_pct"] / 100), 1)
        billable_ratio = random.uniform(MIN_BILLABLE_RATIO, MAX_BILLABLE_RATIO)
        billable_hours = round(hours * billable_ratio, 2)
        internal_hours = round(hours - billable_hours, 2)

        for work_date in _working_days(allocation["start_date"], allocation["end_date"]):
            rows.append({
                "timesheet_id": timesheet_id,
                "allocation_id": allocation["allocation_id"],
                "project_id": allocation["project_id"],
                "employee_id": allocation["employee_id"],
                "work_date": str(work_date),
                "hours": hours,
                "billable_hours": billable_hours,
                "internal_hours": internal_hours,
            })
            timesheet_id += 1

    output_path = OPS_DATA_DIR / "ops_timesheets.csv"
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)

    print(f"ops_timesheets.csv: {len(rows)} records written")


if __name__ == "__main__":
    main()
