from __future__ import annotations

import csv
import os
import random
from datetime import date, timedelta
from typing import Any

import duckdb

SEED = 42
START_DATE = date(2024, 4, 5)
END_DATE = date(2026, 4, 5)
RESOURCES_CSV = "setup/finops/data/finops_cloud_resources.csv"
OPS_PROJECTS_CSV = "setup/ops/data/ops_projects.csv"
OUTPUT_DIR = "setup/finops/data"
OUTPUT_FILE = f"{OUTPUT_DIR}/finops_daily_billing.csv"

# Usage unit and unit_cost range (per unit/day) by service_type.
# unit_cost ranges are calibrated so usage_quantity values are realistic:
#   Compute/Container: vCPU-hours  (~0.04–0.12 $/vCPU-hr; 24 hr/day baseline)
#   Database:          vCPU-hours  (~0.08–0.20 $/vCPU-hr; managed DB premium)
#   Storage:           GB-days     (~0.0008–0.002 $/GB/day; ~$0.02–0.06/GB-month)
#   Serverless:        k-requests  (~0.0002–0.001 $/k-req; millions of calls/day)
SERVICE_TYPE_UNITS: dict[str, tuple[str, float, float]] = {
    "Compute":   ("vCPU-hours",  0.040, 0.120),
    "Container": ("vCPU-hours",  0.030, 0.100),
    "Database":  ("vCPU-hours",  0.080, 0.200),
    "Storage":   ("GB-days",     0.0008, 0.002),
    "Serverless": ("k-requests", 0.0002, 0.001),
}

FIELDNAMES = [
    "billing_id",
    "resource_id",
    "project_id",
    "billing_date",
    "usage_quantity",
    "usage_unit",
    "unit_cost",
    "discount_pct",
    "daily_cost",
]


def main() -> None:
    con = duckdb.connect()

    # Step 1 — Load resources
    resource_rows = con.execute(
        f"SELECT * FROM read_csv_auto('{RESOURCES_CSV}')"
    ).fetchall()
    col_names = [d[0] for d in con.description]
    resources: list[dict[str, Any]] = [
        dict(zip(col_names, row)) for row in resource_rows
    ]

    # Step 2 — Build date → project_id map for ENG/PS resources.
    # ops_projects.csv has no department_id; all projects are PS/ENG work.
    # Where projects overlap on a date, use the lowest project_id (deterministic).
    projects = con.execute(
        f"SELECT project_id, start_date, end_date FROM read_csv_auto('{OPS_PROJECTS_CSV}')"
    ).fetchall()
    con.close()

    date_to_project: dict[date, int] = {}
    for proj_id, start, end in projects:
        d = start if isinstance(start, date) else date.fromisoformat(str(start))
        e = end if isinstance(end, date) else date.fromisoformat(str(end))
        while d <= e:
            if d not in date_to_project or proj_id < date_to_project[d]:
                date_to_project[d] = proj_id
            d += timedelta(days=1)

    eng_ps_depts = {"DEPT-ENG", "DEPT-PS"}

    # Step 3 — Generate billing rows
    rng = random.Random(SEED)
    total_days = (END_DATE - START_DATE).days + 1  # 731

    rows: list[dict[str, Any]] = []
    billing_id = 1

    for resource in sorted(resources, key=lambda r: int(r["resource_id"])):
        service_type = resource["service_type"]
        usage_unit, unit_cost_low, unit_cost_high = SERVICE_TYPE_UNITS[service_type]

        # Per-resource constants drawn once in resource_id order for determinism
        growth_rate = rng.uniform(0.05, 0.15)
        project_mult = rng.uniform(1.2, 1.5)
        unit_cost = round(rng.uniform(unit_cost_low, unit_cost_high), 6)
        discount_pct = round(rng.uniform(0.0, 25.0), 2)
        effective_rate = unit_cost * (1.0 - discount_pct / 100.0)

        # Build spike map: usage spikes (1.5–3×) that naturally inflate daily_cost
        spike_map: dict[date, float] = {}
        for year in [2024, 2025, 2026]:
            num_spikes = rng.randint(3, 5)
            for _ in range(num_spikes):
                spike_start_offset = rng.randint(0, 364)
                spike_duration = rng.randint(1, 5)
                spike_multiplier = rng.uniform(1.5, 3.0)
                spike_start = date(year, 1, 1) + timedelta(days=spike_start_offset)
                for j in range(spike_duration):
                    spike_day = spike_start + timedelta(days=j)
                    if spike_day not in spike_map or spike_map[spike_day] < spike_multiplier:
                        spike_map[spike_day] = spike_multiplier

        current_date = START_DATE
        day_index = 0
        while current_date <= END_DATE:
            growth_mult = 1.0 + growth_rate * (day_index / (total_days - 1))
            # Base daily cost derived from monthly_base_cost
            base_daily_cost = float(resource["monthly_base_cost"]) / 30.0 * growth_mult

            usage_mult = spike_map.get(current_date, 1.0)

            active_project_id: int | None = None
            if resource["department_id"] in eng_ps_depts:
                active_project_id = date_to_project.get(current_date)

            if active_project_id:
                usage_mult *= project_mult

            # Derive usage_quantity from the target cost so unit economics are consistent
            target_cost = base_daily_cost * usage_mult
            usage_quantity = round(
                max(target_cost / effective_rate, 0.0001), 4
            )
            daily_cost = round(max(usage_quantity * effective_rate, 0.01), 2)

            rows.append({
                "billing_id": billing_id,
                "resource_id": resource["resource_id"],
                "project_id": active_project_id,
                "billing_date": current_date.isoformat(),
                "usage_quantity": usage_quantity,
                "usage_unit": usage_unit,
                "unit_cost": unit_cost,
                "discount_pct": discount_pct,
                "daily_cost": daily_cost,
            })

            billing_id += 1
            current_date += timedelta(days=1)
            day_index += 1

    # Step 4 — Write output
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)
    print(f"Written {len(rows)} billing rows to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
