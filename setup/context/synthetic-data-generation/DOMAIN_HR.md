# Phase 1: HR & Talent Management Domain

## Overview

The HR domain represents the backbone of our fictional data platform company. As a hybrid Services and SaaS company focused on the APAC region, the workforce is distributed across multiple countries. This data domain is crucial for analyzing labor costs, employee retention, and regional growth.

## Key Concepts to Simulate

1.  **Geographic Distribution:** Our company operates in Singapore (HQ/Sales), Vietnam (Engineering hubs in Ho Chi Minh City & Hanoi), and Indonesia (Engineering & Consulting in Jakarta).
2.  **Multi-Currency:** Salaries are paid in local currencies (SGD, VND, IDR), which will require downstream currency conversion models in the data warehouse to calculate unified profitability.
3.  **Historical Tracking (SCD Type 2):** Employee roles and salaries change over time. We will simulate "Employee Events" to capture hires, promotions, salary bumps, and terminations, allowing us to perform point-in-time historical analytics.

---

## Schema Definitions

### 1. `hr_locations`

Represents the physical offices where employees are based.

| Field         | Type          | Description                    | Generation Rules / Realism                   |
| :------------ | :------------ | :----------------------------- | :------------------------------------------- |
| `location_id` | String (UUID) | Primary Key                    | Auto-generated ID.                           |
| `city`        | String        | City name                      | Singapore, Ho Chi Minh City, Hanoi, Jakarta. |
| `country`     | String        | Country name                   | Singapore, Vietnam, Indonesia.               |
| `currency`    | String        | Local currency code            | SGD, VND, IDR.                               |
| `office_type` | String        | Primary function of the office | HQ, Engineering Hub, Regional Office.        |

### 2. `hr_departments`

Represents the internal organizational structure.

| Field             | Type          | Description            | Generation Rules / Realism                                        |
| :---------------- | :------------ | :--------------------- | :---------------------------------------------------------------- |
| `department_id`   | String (UUID) | Primary Key            | Auto-generated ID.                                                |
| `department_name` | String        | Name of the department | Engineering (SaaS), Professional Services, Sales, Operations, HR. |
| `cost_center`     | String        | Accounting code        | E.g., ENG-001, PS-001, SLS-001.                                   |

### 3. `hr_employees`

The core dimension table holding current state and demographic information for each employee.

| Field           | Type          | Description               | Generation Rules / Realism                                    |
| :-------------- | :------------ | :------------------------ | :------------------------------------------------------------ |
| `employee_id`   | String (UUID) | Primary Key               | Auto-generated ID.                                            |
| `first_name`    | String        | Employee's first name     | Faker `first_name`.                                           |
| `last_name`     | String        | Employee's last name      | Faker `last_name`.                                            |
| `email`         | String        | Corporate email address   | format: `{first_name}.{last_name}@company.com`.               |
| `department_id` | String (UUID) | Foreign Key               | Reference to `hr_departments`.                                |
| `location_id`   | String (UUID) | Foreign Key               | Reference to `hr_locations`.                                  |
| `hire_date`     | Date          | Date the employee joined  | Skewed towards the last 2-3 years to simulate startup growth. |
| `status`        | String        | Current employment status | Active, Terminated (approx 10-15% termination rate).          |

### 4. `hr_employee_events` (SCD Type 2)

A slowly changing dimension table tracking the history of an employee's career progression and compensation.

| Field            | Type          | Description                     | Generation Rules / Realism                                           |
| :--------------- | :------------ | :------------------------------ | :------------------------------------------------------------------- |
| `event_id`       | String (UUID) | Primary Key                     | Auto-generated ID.                                                   |
| `employee_id`    | String (UUID) | Foreign Key                     | Reference to `hr_employees`.                                         |
| `effective_date` | Date          | Date the change took effect     | Must be >= `hire_date`.                                              |
| `event_type`     | String        | Reason for the record           | Hire, Promotion, Salary Adjustment, Transfer, Termination.           |
| `title`          | String        | Job title at this point in time | e.g., Junior Data Engineer, Senior Data Engineer, Account Executive. |
| `salary`         | Decimal       | Annual base salary              | Generated based on Location (currency) and Title (seniority level).  |

---

## Snowfakery Implementation Notes

- **Locations & Departments:** We will generate a fixed number of these first so they can be referenced by Employees.
- **Probabilities:** We will use Snowfakery's `random_choice` to weight employee distribution (e.g., 60% of the workforce in Engineering/Professional Services, heavily weighted towards VN and ID; Sales heavily weighted towards SG).
- **Salary Logic:** We will utilize Jinja templates in the YAML recipe to ensure salary bands make logical sense (e.g., A Senior Engineer in Singapore earns ~120k SGD, while in Vietnam they might earn ~900M VND).
- **Event Generation:** Every employee will have at least one event (`Hire`). A subset will have subsequent events (`Promotion`, `Termination`) generated chronologically after their hire date.
