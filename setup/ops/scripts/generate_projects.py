from __future__ import annotations

import csv
import random
from datetime import date, timedelta
from pathlib import Path

import duckdb

SEED = 42
TODAY = date(2026, 4, 5)
SERVICES_OFFERING_TYPES = ("Services New Logo", "Cross-sell Services", "Hybrid Expansion")

PROJECT_ROOT = Path(__file__).parent.parent.parent.parent
SF_DATA_DIR = PROJECT_ROOT / "setup" / "salesforce" / "data"
HR_DATA_DIR = PROJECT_ROOT / "setup" / "hr" / "data"
OUTPUT_DIR = Path(__file__).parent.parent / "data"

OUTPUT_FIELDS = [
    "project_id",
    "opportunity_id",
    "account_id",
    "name",
    "project_type",
    "billing_model",
    "budget",
    "start_date",
    "end_date",
    "status",
    "project_manager_id",
]


def _add_months(d: date, months: int) -> date:
    return d + timedelta(days=months * 30)


def _derive_status(start: date, end: date, today: date) -> str:
    if start > today:
        return "Planning"
    if end < today:
        return "Completed"
    return "Active"


def _load_opportunities(con: duckdb.DuckDBPyConnection) -> list[dict]:
    path = str(SF_DATA_DIR / "Opportunity.csv")
    sql = f"""
        SELECT
            CAST(id AS INTEGER)                       AS opportunity_id,
            CAST(AccountId AS INTEGER)                AS account_id,
            Name                                      AS name,
            Offering_Type__c                          AS project_type,
            Contract_Model__c                         AS billing_model,
            CAST(Amount AS DECIMAL(14,2))             AS budget,
            CAST(CloseDate AS DATE)                   AS start_date,
            CAST(Implementation_Months__c AS INTEGER) AS impl_months
        FROM read_csv_auto('{path}')
        WHERE StageName = 'Closed Won'
          AND Offering_Type__c IN ('Services New Logo', 'Cross-sell Services', 'Hybrid Expansion')
        ORDER BY CAST(id AS INTEGER)
    """
    cur = con.execute(sql)
    columns = [desc[0] for desc in cur.description]
    return [dict(zip(columns, row)) for row in cur.fetchall()]


def _load_ps_managers(con: duckdb.DuckDBPyConnection) -> list[int]:
    path = str(HR_DATA_DIR / "hr_employees.csv")
    sql = f"""
        SELECT
            CAST(employee_id AS INTEGER) AS employee_id,
            manager_id
        FROM read_csv_auto('{path}')
        WHERE department_id = 'DEPT-PS'
        ORDER BY CAST(employee_id AS INTEGER)
    """
    cur = con.execute(sql)
    columns = [desc[0] for desc in cur.description]
    rows = [dict(zip(columns, row)) for row in cur.fetchall()]

    # Find the director: DEPT-PS employee where manager_id is empty string or None
    director = None
    for e in rows:
        mgr = e["manager_id"]
        if mgr is None or str(mgr).strip() == "":
            director = e
            break

    if director is None:
        # Fallback: use first employee
        director = rows[0]

    # Find team leads: employees whose manager_id == director's employee_id
    dir_id = str(director["employee_id"])
    leads = [e for e in rows if str(e["manager_id"]) == dir_id]

    if leads:
        leads_sorted = sorted(leads, key=lambda e: e["employee_id"])
        assignment_list = [director] + leads_sorted
    else:
        assignment_list = [director]

    return [e["employee_id"] for e in assignment_list]


def main() -> None:
    # Validate upstream CSVs exist
    required_files = [
        SF_DATA_DIR / "Opportunity.csv",
        SF_DATA_DIR / "Account.csv",
        HR_DATA_DIR / "hr_employees.csv",
    ]
    for f in required_files:
        if not f.exists():
            print(f"ERROR: Required upstream file not found: {f}")
            raise SystemExit(1)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(":memory:")

    opps = _load_opportunities(con)
    managers = _load_ps_managers(con)

    random.seed(SEED)

    projects = []
    for i, opp in enumerate(opps, start=1):
        start_date = opp["start_date"]
        end_date = _add_months(start_date, opp["impl_months"])
        status = _derive_status(start_date, end_date, TODAY)
        project_manager_id = managers[(i - 1) % len(managers)]

        projects.append({
            "project_id": i,
            "opportunity_id": opp["opportunity_id"],
            "account_id": opp["account_id"],
            "name": opp["name"],
            "project_type": opp["project_type"],
            "billing_model": opp["billing_model"],
            "budget": f"{opp['budget']:.2f}",
            "start_date": str(start_date),
            "end_date": str(end_date),
            "status": status,
            "project_manager_id": project_manager_id,
        })

    output_path = OUTPUT_DIR / "ops_projects.csv"
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(projects)

    print(f"ops_projects.csv: {len(projects)} records written")


if __name__ == "__main__":
    main()
