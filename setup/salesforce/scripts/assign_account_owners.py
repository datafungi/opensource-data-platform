"""
Assign Account_Owner_Employee_ID__c on existing Salesforce Accounts.

Reads active DEPT-SALES employees from HR data and distributes them across
Accounts using a round-robin pattern grouped by BillingCountry. The field
stores the HR system employee_id integer as a cross-system FK for analytics
joins — no Salesforce User record required.

Deploy the custom field before running:
    sf project deploy start --source-dir setup/salesforce/force-app

Usage:
    uv run python setup/salesforce/scripts/assign_account_owners.py
    uv run python setup/salesforce/scripts/assign_account_owners.py --dry-run
    uv run python setup/salesforce/scripts/assign_account_owners.py --target-org dev-org
"""

from __future__ import annotations

import argparse
import csv
from itertools import cycle
from pathlib import Path

from sf_auth import get_salesforce_connection
from simple_salesforce.api import Salesforce

HR_EMPLOYEES_PATH = (
    Path(__file__).resolve().parent.parent.parent / "hr" / "data" / "hr_employees.csv"
)
_SALES_DEPT = "DEPT-SALES"


def read_hr_sales_employees() -> list[dict]:
    """Return active DEPT-SALES employees sorted by employee_id."""
    employees = []
    with open(HR_EMPLOYEES_PATH, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["department_id"] == _SALES_DEPT and row["is_active"] == "true":
                employees.append(row)
    employees.sort(key=lambda e: int(e["employee_id"]))
    return employees


def fetch_accounts(sf: Salesforce) -> list[dict]:
    """Return all Accounts with Id, BillingCountry, and current Account_Owner_Employee_ID__c."""
    rows = sf.query_all(
        "SELECT Id, BillingCountry, Account_Owner_Employee_ID__c FROM Account"
    )["records"]
    return [
        {
            "Id": r["Id"],
            "BillingCountry": r["BillingCountry"],
            "Account_Owner_Employee_ID__c": r["Account_Owner_Employee_ID__c"],
        }
        for r in rows
    ]


def build_assignments(
    accounts: list[dict],
    employee_ids: list[int],
) -> list[dict]:
    """
    Round-robin assign employee_ids to accounts within each BillingCountry
    group so accounts from the same country tend to share owners.
    Returns only records where the value would change.
    """
    assignments: list[dict] = []
    country_groups: dict[str, list[dict]] = {}
    for acc in accounts:
        country = acc["BillingCountry"] or "Unknown"
        country_groups.setdefault(country, []).append(acc)

    for _country, group in sorted(country_groups.items()):
        owner_cycle = cycle(employee_ids)
        for acc in group:
            new_id = next(owner_cycle)
            if acc["Account_Owner_Employee_ID__c"] != new_id:
                assignments.append({"Id": acc["Id"], "Account_Owner_Employee_ID__c": new_id})

    return assignments


def bulk_update(sf: Salesforce, records: list[dict]) -> tuple[int, int]:
    results = sf.bulk.Account.update(records, batch_size=200)
    success = sum(1 for r in results if r.get("success"))
    return success, len(records) - success


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-org", default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    employees = read_hr_sales_employees()
    print(f"Active DEPT-SALES employees: {len(employees)}")
    if not employees:
        raise SystemExit("No active DEPT-SALES employees found in HR data.")

    employee_ids = [int(e["employee_id"]) for e in employees]

    sf = get_salesforce_connection(target_org=args.target_org)
    accounts = fetch_accounts(sf)
    print(f"Existing SF accounts: {len(accounts)}")

    assignments = build_assignments(accounts, employee_ids)
    print(f"Accounts to update: {len(assignments)}")

    if args.dry_run:
        print("\n[dry-run] First 20 assignments:")
        for a in assignments[:20]:
            print(
                f"  Account {a['Id']} → Account_Owner_Employee_ID__c={a['Account_Owner_Employee_ID__c']}"
            )
        if len(assignments) > 20:
            print(f"  ... and {len(assignments) - 20} more")
        return

    if not assignments:
        print("Nothing to update.")
        return

    success, failed = bulk_update(sf, assignments)
    print(f"\nDone. Updated={success}, Failed={failed}")


if __name__ == "__main__":
    main()
