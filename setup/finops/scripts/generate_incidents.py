from __future__ import annotations

import csv
import os
import random
from datetime import date, datetime, timedelta
from typing import Any

import duckdb

SEED = 42
TOTAL_INCIDENTS = 300
START_DATE = date(2024, 4, 5)
END_DATE = date(2026, 4, 5)
RESOURCES_CSV = "setup/finops/data/finops_cloud_resources.csv"
OPS_PROJECTS_CSV = "setup/ops/data/ops_projects.csv"
OUTPUT_DIR = "setup/finops/data"
OUTPUT_FILE = f"{OUTPUT_DIR}/eng_incidents.csv"

TTR_RANGES: dict[str, tuple[float, float]] = {
    "P1": (0.5, 4.0),
    "P2": (4.0, 24.0),
    "P3": (24.0, 168.0),
    "P4": (168.0, 720.0),
}
SEVERITY_WEIGHTS = [("P1", 0.05), ("P2", 0.20), ("P3", 0.40), ("P4", 0.35)]

INCIDENT_TYPE_WEIGHTS = [
    ("DEGRADED",   0.30),
    ("OUTAGE",     0.15),
    ("NETWORK",    0.15),
    ("CONFIG",     0.15),
    ("CAPACITY",   0.10),
    ("DEPENDENCY", 0.10),
    ("SECURITY",   0.03),
    ("DATA_LOSS",  0.02),
]

FIELDNAMES = [
    "incident_id",
    "resource_id",
    "project_id",
    "incident_type_code",
    "severity",
    "started_at",
    "resolved_at",
    "time_to_resolve_hours",
    "department_id",
]


def main() -> None:
    # Step 1 — Load resources
    con = duckdb.connect()
    rows = con.execute(
        f"SELECT resource_id, department_id FROM read_csv_auto('{RESOURCES_CSV}')"
    ).fetchall()

    # Step 2 — Build date → project_id map (same logic as generate_billing.py)
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
    resources: list[dict[str, Any]] = [
        {"resource_id": r[0], "department_id": r[1]} for r in rows
    ]

    # Step 2 — Build weighted resource pool (ENG weight=3, others weight=1)
    weighted_pool: list[dict[str, Any]] = []
    for r in resources:
        weight = 3 if r["department_id"] == "DEPT-ENG" else 1
        weighted_pool.extend([r] * weight)

    # Step 3 — Generate 300 incidents
    rng = random.Random(SEED)
    severities = [s for s, _ in SEVERITY_WEIGHTS]
    weights_only = [w for _, w in SEVERITY_WEIGHTS]
    incident_types = [t for t, _ in INCIDENT_TYPE_WEIGHTS]
    incident_type_weights = [w for _, w in INCIDENT_TYPE_WEIGHTS]
    total_days = (END_DATE - START_DATE).days  # 730

    incidents: list[dict[str, Any]] = []
    for i in range(TOTAL_INCIDENTS):
        resource = rng.choice(weighted_pool)
        severity = rng.choices(severities, weights=weights_only, k=1)[0]
        incident_type_code = rng.choices(incident_types, weights=incident_type_weights, k=1)[0]
        started_offset_days = rng.randint(0, total_days - 1)
        started_offset_secs = rng.randint(0, 86399)
        started_at = datetime(
            START_DATE.year, START_DATE.month, START_DATE.day
        ) + timedelta(days=started_offset_days, seconds=started_offset_secs)
        ttr_low, ttr_high = TTR_RANGES[severity]
        ttr_hours = rng.uniform(ttr_low, ttr_high)
        resolved_at = started_at + timedelta(hours=ttr_hours)
        time_to_resolve_hours = round(ttr_hours, 2)

        incident_date = started_at.date()
        active_project_id: int | None = date_to_project.get(incident_date)

        incidents.append({
            "incident_id": i + 1,
            "resource_id": resource["resource_id"],
            "project_id": active_project_id,
            "incident_type_code": incident_type_code,
            "severity": severity,
            "started_at": started_at.strftime("%Y-%m-%d %H:%M:%S"),
            "resolved_at": resolved_at.strftime("%Y-%m-%d %H:%M:%S"),
            "time_to_resolve_hours": time_to_resolve_hours,
            "department_id": resource["department_id"],
        })

    # Step 4 — Write output
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(incidents)
    print(f"Written {TOTAL_INCIDENTS} incidents to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
