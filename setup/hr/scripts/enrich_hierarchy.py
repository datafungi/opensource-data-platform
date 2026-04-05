from __future__ import annotations

import csv
from pathlib import Path

DATA_DIR = Path(__file__).parent.parent / "data"

DEPARTMENTS = ["DEPT-PS", "DEPT-ENG", "DEPT-SALES", "DEPT-HR", "DEPT-FIN"]

SENIOR_KEYWORDS = (
    "Senior",
    "Principal",
    "Director",
    "Lead",
    "Staff",
    "Controller",
    "Head of",
)

EMPLOYEE_FIELDS = [
    "employee_id",
    "first_name",
    "last_name",
    "email",
    "job_title",
    "department_id",
    "location_id",
    "hire_date",
    "termination_date",
    "current_salary",
    "salary_currency",
    "is_active",
    "manager_id",
]


def _assign_tier(job_title: str) -> str:
    if "Junior" in job_title:
        return "Junior"
    if any(kw in job_title for kw in SENIOR_KEYWORDS):
        return "Senior"
    return "Mid"


def _tier_rank(job_title: str) -> int:
    tier = _assign_tier(job_title)
    if tier == "Senior":
        return 2
    if tier == "Mid":
        return 1
    return 0


def _assign_hierarchy(employees: list[dict]) -> list[dict]:
    for dept_id in DEPARTMENTS:
        dept_emps = [e for e in employees if e["department_id"] == dept_id]
        if not dept_emps:
            continue

        # 1. Pick Director: most senior in dept (cross-location), tiebreak earliest hire_date
        sorted_by_seniority = sorted(
            dept_emps,
            key=lambda e: (-_tier_rank(e["job_title"]), e["hire_date"]),
        )
        director = sorted_by_seniority[0]
        director["manager_id"] = ""

        # 2. Per-location: assign Leads (→ Director) and ICs (→ same-location Lead)
        locations = sorted({e["location_id"] for e in dept_emps if e["employee_id"] != director["employee_id"]})

        for loc_id in locations:
            loc_emps = [
                e for e in dept_emps
                if e["location_id"] == loc_id and e["employee_id"] != director["employee_id"]
            ]
            if not loc_emps:
                continue

            loc_sorted = sorted(
                loc_emps,
                key=lambda e: (-_tier_rank(e["job_title"]), e["hire_date"]),
            )

            lead_count = max(1, len(loc_sorted) // 6)
            leads = loc_sorted[:lead_count]
            ics = loc_sorted[lead_count:]

            for lead in leads:
                lead["manager_id"] = director["employee_id"]

            for i, ic in enumerate(ics):
                ic["manager_id"] = leads[i % lead_count]["employee_id"]

    return employees


def main() -> None:
    employees_path = DATA_DIR / "hr_employees.csv"

    with open(employees_path, newline="") as f:
        employees = list(csv.DictReader(f))

    for emp in employees:
        emp.setdefault("manager_id", "")

    updated = _assign_hierarchy(employees)

    with open(employees_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=EMPLOYEE_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(updated)

    from collections import defaultdict

    by_dept: dict[str, list[dict]] = defaultdict(list)
    for emp in updated:
        by_dept[emp["department_id"]].append(emp)

    for dept_id in DEPARTMENTS:
        emps = by_dept.get(dept_id, [])
        if not emps:
            continue
        directors = [e for e in emps if e.get("manager_id", "") == ""]
        dir_id = directors[0]["employee_id"] if directors else ""
        leads = [e for e in emps if e.get("manager_id", "") == dir_id and dir_id != ""]
        ics = [e for e in emps if e not in directors and e not in leads]
        print(
            f"{dept_id}: total={len(emps)}, directors={len(directors)}, "
            f"leads={len(leads)}, ics={len(ics)}"
        )

    print("Hierarchy enrichment complete.")


if __name__ == "__main__":
    main()
