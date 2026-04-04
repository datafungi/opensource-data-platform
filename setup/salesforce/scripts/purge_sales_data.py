"""
Delete all Opportunity, Contact, and Account records from the target org.

Usage:
    uv run python setup/salesforce/scripts/purge_sales_data.py --target-org dev-org --yes
"""

from __future__ import annotations

import argparse

from simple_salesforce.api import Salesforce

from sf_auth import get_salesforce_connection


def bulk_delete_all(sf: Salesforce, sobject: str) -> tuple[int, int]:
    rows = sf.query_all(f"SELECT Id FROM {sobject}")["records"]
    records = [{"Id": row["Id"]} for row in rows]
    if not records:
        return 0, 0

    results = getattr(sf.bulk, sobject).delete(records, batch_size=200)
    success = sum(1 for item in results if item.get("success"))
    failed = len(records) - success
    return success, failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-org", default="dev-org")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirm destructive delete action.",
    )
    args = parser.parse_args()

    if not args.yes:
        raise SystemExit("Refusing to delete data without --yes.")

    sf = get_salesforce_connection(target_org=args.target_org)
    for sobject in ["Opportunity", "Contact", "Account"]:
        success, failed = bulk_delete_all(sf, sobject)
        print(f"{sobject}: deleted={success}, failed={failed}")


if __name__ == "__main__":
    main()
