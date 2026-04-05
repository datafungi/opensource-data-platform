from __future__ import annotations

import csv
import random
import uuid
from datetime import date, timedelta
from pathlib import Path

TERMINATION_RATE = 0.15
PROMOTION_DELAY_MONTHS = 18
DATA_DIR = Path(__file__).parent.parent / "data"
CUTOFF_DATE = date(2026, 4, 5)

SALARY_BANDS: dict[str, dict[str, tuple[int, int]]] = {
    "SGD": {"Junior": (4000, 6000), "Mid": (6000, 9000), "Senior": (9000, 15000)},
    "VND": {
        "Junior": (15_000_000, 25_000_000),
        "Mid": (25_000_000, 40_000_000),
        "Senior": (40_000_000, 70_000_000),
    },
    "IDR": {
        "Junior": (8_000_000, 14_000_000),
        "Mid": (14_000_000, 22_000_000),
        "Senior": (22_000_000, 40_000_000),
    },
}

TIER_ORDER = ["Junior", "Mid", "Senior"]

# Keywords that indicate Senior tier (checked after "Junior" check)
SENIOR_KEYWORDS = (
    "Senior",
    "Principal",
    "Director",
    "Lead",
    "Staff",
    "Controller",
    "Head of",
)

EVENT_FIELDS = [
    "event_id",
    "employee_id",
    "event_type",
    "effective_date",
    "old_salary",
    "new_salary",
    "old_job_title",
    "new_job_title",
]

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
]


def _assign_tier(job_title: str) -> str:
    if "Junior" in job_title:
        return "Junior"
    if any(kw in job_title for kw in SENIOR_KEYWORDS):
        return "Senior"
    return "Mid"


def _get_next_tier(current_tier: str) -> str:
    idx = TIER_ORDER.index(current_tier)
    if idx >= len(TIER_ORDER) - 1:
        return "Senior"
    return TIER_ORDER[idx + 1]


def _random_salary(currency: str, tier: str) -> int:
    low, high = SALARY_BANDS[currency][tier]
    return random.randint(low, high)


def _get_promotion_salary(currency: str, current_tier: str, current_salary: int) -> int:
    next_tier = _get_next_tier(current_tier)
    low, high = SALARY_BANDS[currency][next_tier]
    candidate = random.randint(low, high)
    if candidate <= current_salary:
        candidate = current_salary + 1
    return candidate


def _add_months(d: date, months: int) -> date:
    return d + timedelta(days=months * 30)


def _make_event_id() -> str:
    return "EVT-" + str(uuid.uuid4())[:8].upper()


def _promote_title(job_title: str, current_tier: str) -> str:
    if current_tier == "Junior":
        return job_title.replace("Junior ", "", 1)
    if current_tier == "Mid":
        return "Senior " + job_title
    return job_title


def _promotion_rate(months_since_eligible: float) -> float:
    """Tenure-based promotion probability.

    Employees eligible for 36+ months are near-certain to be promoted;
    shorter tenures scale down proportionally.
    """
    if months_since_eligible >= 36:
        return 0.95
    if months_since_eligible >= 24:
        return 0.80
    return 0.65


def _assign_emails(employees: list[dict]) -> None:
    """Rewrite email field as firstname.lastname@datafungi.net with deduplication.

    First occurrence: john.smith@datafungi.net
    Subsequent occurrences: john.smith2@datafungi.net, john.smith3@datafungi.net, ...
    Modifies the list in-place.
    """
    seen: dict[str, int] = {}
    for emp in employees:
        first = emp["first_name"].lower().replace(" ", "")
        last = emp["last_name"].lower().replace(" ", "")
        base = f"{first}.{last}"
        count = seen.get(base, 0) + 1
        seen[base] = count
        suffix = "" if count == 1 else str(count)
        emp["email"] = f"{base}{suffix}@datafungi.net"


def build_events(employees: list[dict]) -> tuple[list[dict], list[dict]]:
    updated_employees: list[dict] = []
    all_events: list[dict] = []

    for emp in employees:
        hire_date = date.fromisoformat(emp["hire_date"])
        currency = emp["salary_currency"]
        hire_title = emp["job_title"]
        current_tier = _assign_tier(hire_title)

        # Compute hire salary from tier (ignore recipe placeholder value)
        hire_salary = _random_salary(currency, current_tier)

        emp_events: list[dict] = []

        # 1. Hire event (always)
        emp_events.append({
            "event_id": _make_event_id(),
            "employee_id": emp["employee_id"],
            "event_type": "Hire",
            "effective_date": hire_date.isoformat(),
            "old_salary": "",
            "old_job_title": "",
            "new_salary": hire_salary,
            "new_job_title": hire_title,
        })

        current_salary = hire_salary
        current_title = hire_title
        base_date = hire_date
        is_active = True
        termination_date: date | None = None

        # 2. Promotions — tenure-based, up to 2 rounds
        for _ in range(2):
            if current_tier == "Senior":
                break
            months_since_base = (CUTOFF_DATE - base_date).days / 30
            if months_since_base < PROMOTION_DELAY_MONTHS:
                break
            if random.random() > _promotion_rate(months_since_base):
                break

            promo_date = _add_months(base_date, PROMOTION_DELAY_MONTHS)
            if promo_date > CUTOFF_DATE:
                break

            new_salary = _get_promotion_salary(currency, current_tier, current_salary)
            new_title = _promote_title(current_title, current_tier)
            emp_events.append({
                "event_id": _make_event_id(),
                "employee_id": emp["employee_id"],
                "event_type": "Promotion",
                "effective_date": promo_date.isoformat(),
                "old_salary": current_salary,
                "old_job_title": current_title,
                "new_salary": new_salary,
                "new_job_title": new_title,
            })
            current_salary = new_salary
            current_title = new_title
            current_tier = _get_next_tier(current_tier)
            base_date = promo_date

        # 3. Termination (~15%)
        if random.random() < TERMINATION_RATE:
            term_date = _add_months(base_date, random.randint(6, 18))
            if term_date <= CUTOFF_DATE:
                emp_events.append({
                    "event_id": _make_event_id(),
                    "employee_id": emp["employee_id"],
                    "event_type": "Termination",
                    "effective_date": term_date.isoformat(),
                    "old_salary": current_salary,
                    "old_job_title": current_title,
                    "new_salary": "",
                    "new_job_title": "",
                })
                is_active = False
                termination_date = term_date

        # 4. Sort events chronologically
        emp_events.sort(key=lambda e: e["effective_date"])

        # 5. Update employee fields
        emp_copy = dict(emp)
        emp_copy["current_salary"] = current_salary
        emp_copy["job_title"] = current_title
        emp_copy["is_active"] = "true" if is_active else "false"
        emp_copy["termination_date"] = termination_date.isoformat() if termination_date else ""
        updated_employees.append(emp_copy)

        all_events.extend(emp_events)

    return updated_employees, all_events


def main() -> None:
    employees_path = DATA_DIR / "hr_employees.csv"
    events_path = DATA_DIR / "hr_employee_events.csv"

    with employees_path.open(newline="", encoding="utf-8") as fh:
        employees = list(csv.DictReader(fh))

    _assign_emails(employees)
    updated_employees, all_events = build_events(employees)

    # Write updated employees (overwrite in place, enforce column order)
    with employees_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=EMPLOYEE_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(updated_employees)

    # Write authoritative events (creates file if absent)
    with events_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=EVENT_FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(all_events)

    hire_count = sum(1 for e in all_events if e["event_type"] == "Hire")
    promo_count = sum(1 for e in all_events if e["event_type"] == "Promotion")
    term_count = sum(1 for e in all_events if e["event_type"] == "Termination")

    print(f"Employees processed: {len(updated_employees)}")
    print(f"Hire events:         {hire_count}")
    print(f"Promotion events:    {promo_count}")
    print(f"Termination events:  {term_count}")
    print(f"Total events:        {len(all_events)}")


if __name__ == "__main__":
    main()
