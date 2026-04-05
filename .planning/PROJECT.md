# Project Context

## What This Is
A synthetic data generation project for an open-source data platform. The goal is to generate realistic, mathematically sound datasets across three primary domains (HR & Talent Management, Operations & Professional Services, and SaaS Infrastructure & FinOps) using Snowfakery. This data will simulate a fictional APAC-focused data platform partner operating a Hybrid Business Model (Services + SaaS) and will be used to power complex downstream analytics.

## Core Value
To provide realistic, relational, and time-series data that enables the demonstration and testing of complex analytics use cases (e.g., Consultant Utilization, Project Profitability, SaaS Margins) within the open-source data platform, complementing the already generated CRM (Salesforce) data.

## Requirements

### Validated
- ✓ Salesforce CRM data generation (Accounts, Contacts, Opportunities, Leads) is already completed.
- ✓ Business model and data schemas for HR, Ops, and FinOps domains are defined.

### Active
- [ ] Write a Snowfakery recipe for Phase 1: HR & Talent Management (Locations, Departments, Employees, Employee Events with SCD Type 2).
- [ ] Write a Snowfakery recipe for Phase 2: Operations & Professional Services (Projects linked to Salesforce Accounts, Resource Allocations linked to HR Employees, and daily Timesheets).
- [ ] Write a Snowfakery recipe for Phase 3: SaaS Infrastructure & FinOps (Cloud Resources, Daily Billing, Engineering Incidents).
- [ ] Implement automation (shell script or Makefile) to run all Snowfakery recipes sequentially.
- [ ] Output all generated files to a centralized directory for downstream ingestion.

### Out of Scope
- Re-generating or modifying the existing Salesforce CRM synthetic data.
- Building the downstream data pipelines (Airbyte/dbt) or analytics dashboards (this project is strictly about data generation).

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Use Snowfakery for data generation | Allows for declarative generation of relational, mathematically sound data, which is essential for complex business models. | — Pending |
| Phase-based implementation (HR -> Ops -> FinOps) | Manages complexity and ensures cross-domain dependencies (e.g., Ops needing HR Employee IDs and CRM Account IDs) are handled sequentially. | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: April 5, 2026 after initialization*
