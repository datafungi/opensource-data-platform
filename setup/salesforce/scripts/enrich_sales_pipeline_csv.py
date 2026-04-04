"""
Populate custom analytics fields in Snowfakery CSV outputs.

Usage:
    uv run python setup/salesforce/scripts/enrich_sales_pipeline_csv.py
"""

from __future__ import annotations

import csv
import random
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
ACCOUNT_PATH = DATA_DIR / "Account.csv"
OPPORTUNITY_PATH = DATA_DIR / "Opportunity.csv"


def read_csv(path: Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def segment_from_employees(employee_count: int) -> str:
    if employee_count >= 5000:
        return "Enterprise"
    if employee_count >= 150:
        return "SME"
    return "Developer Team"


def add_account_custom_fields(rows: list[dict], rng: random.Random) -> dict[str, dict]:
    account_index: dict[str, dict] = {}
    for row in rows:
        description = row.get("Description", "")
        country = row.get("BillingCountry", "")
        employees = int(row.get("NumberOfEmployees", "0") or 0)

        if "SaaS-only customer" in description:
            engagement = "SaaS Only"
            offering = "SaaS"
            parent_type = "Standalone"
            saas_tier = rng.choices(
                ["Free", "Team", "Business", "Enterprise"],
                weights=[10, 35, 35, 20],
                k=1,
            )[0]
            services_line = "None"
        elif "services-only" in description:
            engagement = "Services Only"
            offering = "Services"
            parent_type = "Standalone"
            saas_tier = "None"
            services_line = rng.choice(
                [
                    "Data Strategy & Consultancy",
                    "End-to-End Data Platform",
                    "Cloud Migration",
                    "Managed Data Platform",
                ]
            )
        elif "hybrid" in description:
            engagement = "Hybrid"
            offering = "Hybrid"
            parent_type = "Standalone"
            saas_tier = rng.choice(["Team", "Business", "Enterprise"])
            services_line = rng.choice(
                [
                    "Data Strategy & Consultancy",
                    "End-to-End Data Platform",
                    "Cloud Migration",
                    "Managed Data Platform",
                ]
            )
        elif "services-first relationship" in description:
            engagement = "Services-first Parent"
            offering = "Services"
            parent_type = "Parent"
            saas_tier = rng.choice(["None", "Team", "Business"])
            services_line = rng.choice(
                [
                    "Data Strategy & Consultancy",
                    "End-to-End Data Platform",
                    "Cloud Migration",
                    "Managed Data Platform",
                ]
            )
        elif "SaaS-first relationship" in description:
            engagement = "SaaS-first Parent"
            offering = "SaaS"
            parent_type = "Parent"
            saas_tier = rng.choice(["Team", "Business", "Enterprise"])
            services_line = rng.choice(["None", "Managed Data Platform"])
        elif "services expansion from SaaS-first parent" in description:
            engagement = "Subsidiary - Services Expansion"
            offering = "Services"
            parent_type = "Subsidiary"
            saas_tier = rng.choice(["None", "Free", "Team"])
            services_line = rng.choice(
                [
                    "Data Strategy & Consultancy",
                    "End-to-End Data Platform",
                    "Cloud Migration",
                    "Managed Data Platform",
                ]
            )
        elif "SaaS expansion from services-first parent" in description:
            engagement = "Subsidiary - SaaS Expansion"
            offering = "SaaS"
            parent_type = "Subsidiary"
            saas_tier = rng.choice(["Team", "Business", "Enterprise"])
            services_line = rng.choice(["None", "Managed Data Platform"])
        else:
            engagement = "Hybrid"
            offering = "Hybrid"
            parent_type = "Standalone"
            saas_tier = "Business"
            services_line = "End-to-End Data Platform"

        row["Engagement_Model__c"] = engagement
        row["Primary_Offering__c"] = offering
        row["Region__c"] = "US" if country == "United States" else "APAC"
        row["Customer_Segment__c"] = segment_from_employees(employees)
        row["SaaS_Tier__c"] = saas_tier
        row["Services_Line__c"] = services_line
        row["Parent_Relationship_Type__c"] = parent_type

        account_index[row["id"]] = {
            "engagement": engagement,
            "offering": offering,
        }

    return account_index


def add_opportunity_custom_fields(
    rows: list[dict], account_index: dict[str, dict], rng: random.Random
) -> None:
    for row in rows:
        description = row.get("Description", "")
        amount = int(row.get("Amount", "0") or 0)
        account_attrs = account_index.get(row.get("AccountId", ""), {})
        account_offering = account_attrs.get("offering", "Hybrid")

        if "Subsidiary Services Expansion" in row.get("Name", ""):
            offering_type = "Cross-sell Services"
            cross_sell_from = "SaaS"
            sales_motion = "Expansion"
            contract_model = rng.choice(["Project-based", "Time & Materials", "Retainer"])
            usage_pricing = "None"
            implementation_months = rng.randint(4, 12)
            expected_arr = round(amount * rng.uniform(0.25, 0.55), 2)
        elif "Subsidiary SaaS Expansion" in row.get("Name", ""):
            offering_type = "Cross-sell SaaS"
            cross_sell_from = "Services"
            sales_motion = "Expansion"
            contract_model = "Subscription"
            usage_pricing = rng.choice(
                ["Data Volume", "Pipeline Count", "Metadata Scale", "Hybrid Usage"]
            )
            implementation_months = rng.randint(1, 4)
            expected_arr = round(amount * rng.uniform(0.75, 1.20), 2)
        elif "services" in description.lower():
            offering_type = "Services New Logo"
            cross_sell_from = "None"
            sales_motion = rng.choice(["Outbound", "Partner-led", "Inbound"])
            contract_model = rng.choice(["Project-based", "Time & Materials", "Retainer"])
            usage_pricing = "None"
            implementation_months = rng.randint(3, 12)
            expected_arr = round(amount * rng.uniform(0.20, 0.50), 2)
        elif account_offering == "Hybrid":
            offering_type = "Hybrid Expansion"
            cross_sell_from = "Hybrid"
            sales_motion = "Expansion"
            contract_model = rng.choice(["Subscription", "Retainer"])
            usage_pricing = rng.choice(
                ["Data Volume", "Pipeline Count", "Metadata Scale", "Hybrid Usage"]
            )
            implementation_months = rng.randint(2, 7)
            expected_arr = round(amount * rng.uniform(0.55, 1.00), 2)
        else:
            offering_type = "SaaS New Logo"
            cross_sell_from = "None"
            sales_motion = rng.choice(["Inbound", "Partner-led", "Outbound"])
            contract_model = "Subscription"
            usage_pricing = rng.choice(
                ["Data Volume", "Pipeline Count", "Metadata Scale", "Hybrid Usage"]
            )
            implementation_months = rng.randint(1, 4)
            expected_arr = round(amount * rng.uniform(0.70, 1.15), 2)

        if amount < 90000:
            volume_tier = "Low"
        elif amount < 250000:
            volume_tier = "Medium"
        elif amount < 700000:
            volume_tier = "High"
        else:
            volume_tier = "Very High"

        row["Offering_Type__c"] = offering_type
        row["Sales_Motion__c"] = sales_motion
        row["Cross_Sell_From__c"] = cross_sell_from
        row["Contract_Model__c"] = contract_model
        row["Expected_ARR__c"] = f"{expected_arr:.2f}"
        row["Implementation_Months__c"] = str(implementation_months)
        row["Data_Volume_Tier__c"] = volume_tier
        row["Usage_Pricing_Model__c"] = usage_pricing


def main() -> None:
    rng = random.Random(20260404)
    accounts = read_csv(ACCOUNT_PATH)
    opportunities = read_csv(OPPORTUNITY_PATH)

    account_index = add_account_custom_fields(accounts, rng)
    add_opportunity_custom_fields(opportunities, account_index, rng)

    account_fields = list(accounts[0].keys()) if accounts else []
    opp_fields = list(opportunities[0].keys()) if opportunities else []
    write_csv(ACCOUNT_PATH, accounts, account_fields)
    write_csv(OPPORTUNITY_PATH, opportunities, opp_fields)

    print(f"Enriched {len(accounts)} accounts and {len(opportunities)} opportunities.")


if __name__ == "__main__":
    main()
