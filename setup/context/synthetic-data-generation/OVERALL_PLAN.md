# Synthetic Data Generation: Overall Plan

## 1. Overview and Core Ideas

To build a realistic, modern open-source data platform, we need data that reflects the complexity of a real business. Our fictional company is an APAC-focused data platform partner operating a **Hybrid Business Model**:

1. **Services Engine:** High-impact engineering services, cloud migrations, and data strategy consulting.
2. **SaaS Engine:** Scalable products for data observability and governance.

Because the CRM data (Salesforce) representing our sales pipeline, accounts, and opportunities is already complete, we need to generate internal operational data to simulate the rest of the business.

Using **Snowfakery**, we will generate highly relational, mathematically sound datasets across three primary domains. This data will ultimately be ingested into our data platform to power complex analytics, such as:

- **Consultant Utilization Rates** (Time logged vs. Billable targets)
- **Project Profitability** (Revenue from CRM - HR Labor Costs)
- **SaaS Margins** (SaaS Revenue - Cloud Infrastructure Costs)
- **Employee Retention & Cost Variance** across APAC regions (SGD vs. VND vs. IDR)

---

## 2. Implementation Phases

We will break the data generation down into modular phases. Each phase will have its own dedicated documentation detailing the exact table structures, fields, and generation logic.

### Phase 0: CRM & Sales (Completed)

- Generated realistic Salesforce data (Accounts, Contacts, Opportunities, Leads).
- Represents the revenue side of the Services engine and initial pipeline.

### Phase 1: HR & Talent Management

- **Goal:** Create the backbone of our organization. A distributed workforce is complex, and tracking this over time is crucial for realistic analytics.
- **Key Concepts:** APAC Office Locations (Singapore, Vietnam, Indonesia), Departments, Employees, and Slowly Changing Dimensions (SCD Type 2) for promotions, salary changes, and terminations.
- **Reference Doc:** `DOMAIN_HR.md`

### Phase 2: Operations & Professional Services

- **Goal:** Simulate the execution of our Services Engine. This connects the revenue (Salesforce) to the cost (HR).
- **Key Concepts:** Projects (tied to Salesforce Accounts), Resource Allocations (tying Employees to Projects), and daily Time-Series Timesheets.
- **Reference Doc:** `DOMAIN_OPS.md`

### Phase 3: SaaS Infrastructure & FinOps

- **Goal:** Simulate the underlying cloud costs and operational health of both our internal systems and our SaaS products.
- **Key Concepts:** Cloud Resources (AWS, GCP, Snowflake), daily billing logs, and Engineering Incidents/SLAs.
- **Reference Doc:** `DOMAIN_FINOPS.md`

---

## 3. To-Do List

### Planning & Documentation

- [x] Initial CRM (Salesforce) data generation.
- [x] Define Overall Plan and architecture (`OVERALL_PLAN.md`).
- [ ] Create detailed schema document for HR (`DOMAIN_HR.md`).
- [ ] Create detailed schema document for Operations (`DOMAIN_OPS.md`).
- [ ] Create detailed schema document for SaaS & FinOps (`DOMAIN_FINOPS.md`).
- [ ] Delete the old `DATA_GENERATION_PLAN.md` to avoid confusion.

### Development: Phase 1 (HR)

- [ ] Write Snowfakery recipe (`hr_generation.yml`).
- [ ] Implement local currency and salary band logic using Jinja templates.
- [ ] Implement SCD Type 2 logic for Employee Events.
- [ ] Execute recipe and validate output CSVs.

### Development: Phase 2 (Operations)

- [ ] Write Snowfakery recipe (`ops_generation.yml`).
- [ ] Extract existing Salesforce Account IDs to use as Foreign Keys for Projects.
- [ ] Extract generated HR Employee IDs to use as Foreign Keys for Allocations/Timesheets.
- [ ] Generate 1-2 years of daily timesheet records.
- [ ] Execute recipe and validate output CSVs.

### Development: Phase 3 (FinOps)

- [ ] Write Snowfakery recipe (`finops_generation.yml`).
- [ ] Implement daily time-series looping for cloud billing.
- [ ] Execute recipe and validate output CSVs.

### Automation & Integration

- [ ] Write a shell script or Makefile target to run all Snowfakery recipes sequentially.
- [ ] Output all generated files to a centralized `data/landing` directory for downstream ingestion (e.g., Airbyte/dbt).
