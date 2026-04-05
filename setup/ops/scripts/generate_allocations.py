from __future__ import annotations

import csv
import random
from datetime import date
from pathlib import Path

import duckdb

SEED = 42
MIN_STAFF = 2
MAX_STAFF = 5
PCT_CHOICES = (50, 75, 100)
MAX_UTIL = 120

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
HR_DATA_DIR = PROJECT_ROOT / "setup" / "hr" / "data"
OPS_DATA_DIR = Path(__file__).parent.parent / "data"

OUTPUT_FIELDS = [
    "allocation_id",
    "project_id",
    "employee_id",
    "start_date",
    "end_date",
    "allocation_pct",
]


def _load_projects(con: duckdb.DuckDBPyConnection, projects_path: str) -> list[dict]:
    sql = f"""
        SELECT
            CAST(project_id AS INTEGER) AS project_id,
            CAST(start_date AS DATE)    AS start_date,
            CAST(end_date AS DATE)      AS end_date
        FROM read_csv_auto('{projects_path}')
        ORDER BY start_date, project_id
    """
    cur = con.execute(sql)
    columns = [desc[0] for desc in cur.description]
    return [dict(zip(columns, row)) for row in cur.fetchall()]


def _load_eligible_employees(con: duckdb.DuckDBPyConnection, hr_path: str) -> list[dict]:
    sql = f"""
        SELECT
            CAST(employee_id AS INTEGER) AS employee_id,
            CAST(hire_date AS DATE)      AS hire_date,
            termination_date,
            is_active
        FROM read_csv_auto('{hr_path}')
        WHERE department_id = 'DEPT-PS'
        ORDER BY CAST(employee_id AS INTEGER)
    """
    cur = con.execute(sql)
    columns = [desc[0] for desc in cur.description]
    return [dict(zip(columns, row)) for row in cur.fetchall()]


def _is_eligible(emp: dict, project_start: date) -> bool:
    if emp["hire_date"] > project_start:
        return False
    is_active = emp["is_active"]
    if is_active is True or str(is_active).lower() == "true":
        return True
    term = emp["termination_date"]
    if term and str(term).strip():
        return date.fromisoformat(str(term).strip()) > project_start
    return False


def _overlaps(start1: date, end1: date, start2: date, end2: date) -> bool:
    return start1 <= end2 and start2 <= end1


def _check_utilization(
    allocations: list[dict],
    employee_id: int,
    proj_start: date,
    proj_end: date,
    new_pct: int,
) -> bool:
    existing_util = sum(
        a["allocation_pct"]
        for a in allocations
        if a["employee_id"] == employee_id
        and _overlaps(a["start_date"], a["end_date"], proj_start, proj_end)
    )
    return (existing_util + new_pct) <= MAX_UTIL


def main() -> None:
    # Validate upstream files exist
    required_files = [
        OPS_DATA_DIR / "ops_projects.csv",
        HR_DATA_DIR / "hr_employees.csv",
    ]
    for f in required_files:
        if not f.exists():
            print(f"ERROR: Required upstream file not found: {f}")
            raise SystemExit(1)

    con = duckdb.connect(":memory:")

    projects = _load_projects(con, str(OPS_DATA_DIR / "ops_projects.csv"))
    employees = _load_eligible_employees(con, str(HR_DATA_DIR / "hr_employees.csv"))

    random.seed(SEED)

    all_allocations: list[dict] = []
    allocation_id = 1

    for project in projects:
        eligible = [e for e in employees if _is_eligible(e, project["start_date"])]
        random.shuffle(eligible)
        target_count = random.randint(MIN_STAFF, MAX_STAFF)
        assigned = 0

        for candidate in eligible:
            if assigned >= target_count:
                break
            pct = random.choice(PCT_CHOICES)
            if _check_utilization(
                all_allocations,
                candidate["employee_id"],
                project["start_date"],
                project["end_date"],
                pct,
            ):
                all_allocations.append({
                    "allocation_id": allocation_id,
                    "project_id": project["project_id"],
                    "employee_id": candidate["employee_id"],
                    "start_date": project["start_date"],
                    "end_date": project["end_date"],
                    "allocation_pct": pct,
                })
                allocation_id += 1
                assigned += 1

    output_path = OPS_DATA_DIR / "ops_resource_allocations.csv"
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows([
            {**a, "start_date": str(a["start_date"]), "end_date": str(a["end_date"])}
            for a in all_allocations
        ])

    print(f"ops_resource_allocations.csv: {len(all_allocations)} records written")
    print(
        f"Projects staffed: {len(projects)}, "
        f"avg {len(all_allocations) / len(projects):.1f} employees/project"
    )


if __name__ == "__main__":
    main()
