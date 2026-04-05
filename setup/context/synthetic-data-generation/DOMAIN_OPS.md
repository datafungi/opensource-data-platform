# Phase 2: Operations & Professional Services Domain

## Overview

The Operations domain is the engine that drives the consulting and implementation side of our business. As an APAC-focused data platform partner, we build modern data stacks, perform cloud migrations, and offer managed services.

This data domain connects our revenue pipeline (CRM/Salesforce) to our labor costs (HR). By tracking project assignments and logged hours, we can perform critical business analytics like Consultant Utilization, Project Profitability, and Resource Forecasting.

## Key Concepts to Simulate

1.  **Projects tied to CRM:** Every consulting engagement begins as a "Closed Won" opportunity in Salesforce. Therefore, our Projects must reference real Salesforce `Account IDs`.
2.  **Resource Allocation:** Employees from the "Professional Services" department are assigned to projects. An employee might be dedicated 100% to one project, or split across multiple smaller engagements.
3.  **Time-Series Timesheets:** The core transactional data of any consulting firm. Employees log hours daily against specific projects. This data is required to calculate utilization and billable metrics.

---

## Schema Definitions

### 1. `ops_projects`

Represents the actual consulting engagements we are delivering for our clients.

| Field            | Type          | Description                | Generation Rules / Realism                                                                              |
| :--------------- | :------------ | :------------------------- | :------------------------------------------------------------------------------------------------------ |
| `project_id`     | String (UUID) | Primary Key                | Auto-generated ID.                                                                                      |
| `crm_account_id` | String        | Foreign Key                | Must reference `AccountId` from the previously generated Salesforce synthetic data.                     |
| `project_name`   | String        | Descriptive name           | e.g., "Data Lakehouse Implementation", "AWS Cloud Migration", "Q3 Managed Services".                    |
| `project_type`   | String        | Categorization of work     | Cloud Migration, Data Strategy, End-to-End Data Platform, Managed Platform.                             |
| `start_date`     | Date          | Project kickoff            | Should loosely align with the CRM Opportunity Close Date.                                               |
| `end_date`       | Date          | Expected completion        | `start_date` + 2 to 12 months depending on `project_type`. Managed Services might not have an end date. |
| `status`         | String        | Current state              | Planning, Active, Completed, On Hold.                                                                   |
| `budget`         | Decimal       | Total project budget (USD) | Loosely tied to project duration and type.                                                              |

### 2. `ops_resource_allocations`

Defines which employees are working on which projects, and their expected time commitment.

| Field                   | Type          | Description                | Generation Rules / Realism                                                                                                 |
| :---------------------- | :------------ | :------------------------- | :------------------------------------------------------------------------------------------------------------------------- |
| `allocation_id`         | String (UUID) | Primary Key                | Auto-generated ID.                                                                                                         |
| `project_id`            | String (UUID) | Foreign Key                | Reference to `ops_projects`.                                                                                               |
| `employee_id`           | String (UUID) | Foreign Key                | Reference to `hr_employees` (must be an active employee in Professional Services).                                         |
| `role`                  | String        | Role on the project        | Lead Engineer, Data Engineer, Project Manager.                                                                             |
| `allocation_percentage` | Integer       | Expected commitment        | e.g., 50 (meaning 50% of their time or ~20 hours a week). Total allocations for an active employee shouldn't exceed ~120%. |
| `start_date`            | Date          | When they join the project | Must be >= Project `start_date`.                                                                                           |
| `end_date`              | Date          | When they roll off         | Must be <= Project `end_date`.                                                                                             |

### 3. `ops_timesheets` (Time-Series)

The daily transactional record of work performed by employees.

| Field           | Type          | Description                | Generation Rules / Realism                                                                                      |
| :-------------- | :------------ | :------------------------- | :-------------------------------------------------------------------------------------------------------------- |
| `timesheet_id`  | String (UUID) | Primary Key                | Auto-generated ID.                                                                                              |
| `employee_id`   | String (UUID) | Foreign Key                | Reference to `hr_employees`.                                                                                    |
| `project_id`    | String (UUID) | Foreign Key                | Reference to `ops_projects` (could also include non-billable codes like "Internal" or "Bench").                 |
| `date`          | Date          | Day the work was performed | Generated for weekdays only. Must fall within the employee's `ops_resource_allocations` dates for that project. |
| `hours_logged`  | Decimal       | Amount of time logged      | Usually 4.0 to 8.0 hours. Daily total across all projects for an employee should sum to ~8 hours.               |
| `billable_flag` | Boolean       | Can we charge the client?  | `True` for most project work, `False` for internal meetings or bench time.                                      |

---

## Snowfakery Implementation Notes

- **External ID Lookups:** The biggest challenge in this domain is referencing data generated outside of this specific Snowfakery run.
  - For `crm_account_id`, we will need to load a sample of Account IDs from the Salesforce CSVs into the Snowfakery recipe using a plugin or a pre-processing script.
  - For `employee_id`, we will need to load the IDs generated during Phase 1 (HR).
- **Time-Series Looping:** Generating `ops_timesheets` requires looping over a date range. We will use Snowfakery's capabilities to generate daily records for the past 1-2 years, excluding weekends to maintain realism.
- **Data Integrity:** We must ensure logic dictates that timesheets are only generated for an `employee_id` and `project_id` combination if a valid `ops_resource_allocations` record exists for that date.
