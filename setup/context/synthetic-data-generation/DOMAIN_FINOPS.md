# Phase 3: SaaS Infrastructure & FinOps Domain

## Overview

The FinOps & SaaS Infrastructure domain simulates the backbone of our SaaS product (Data Observability and Governance) and the internal platforms supporting our managed services. As a cloud-native data platform partner, understanding cloud costs and operational health is critical.

This data domain allows us to calculate the true margin of our SaaS offerings (SaaS Revenue - Infrastructure Costs) and track our engineering team's operational excellence (SLA adherence, incident response times).

## Key Concepts to Simulate

1.  **Multi-Cloud & Modern Data Stack:** Our infrastructure spans AWS (compute/storage) and managed data warehouses like Snowflake or BigQuery.
2.  **Daily Cloud Billing (FinOps):** Cloud costs are not static; they fluctuate based on usage, data volume processed, and poorly optimized queries. We will simulate daily billing exports (similar to AWS Cost and Usage Reports).
3.  **Engineering Incidents:** Systems fail. Tracking outages, severity levels, and Time to Resolution (TTR) is vital for measuring the reliability of our SaaS platform and managed service SLAs.

---

## Schema Definitions

### 1. `finops_cloud_resources`

Represents the distinct cloud infrastructure components provisioned by the engineering team.

| Field            | Type          | Description               | Generation Rules / Realism                                 |
| :--------------- | :------------ | :------------------------ | :--------------------------------------------------------- |
| `resource_id`    | String (UUID) | Primary Key               | Auto-generated ID.                                         |
| `cloud_provider` | String        | Hosting provider          | AWS, GCP, Snowflake, Datadog.                              |
| `service_name`   | String        | Specific cloud service    | EC2, S3, BigQuery, Snowflake Compute, RDS, EKS.            |
| `environment`    | String        | Deployment stage          | Production, Staging, Development.                          |
| `team_owner`     | String        | Internal team responsible | SaaS Engineering, Internal DataOps, Professional Services. |
| `cost_center`    | String        | For accounting rollup     | Links back to the `cost_center` in `hr_departments`.       |

### 2. `finops_daily_billing` (Time-Series)

The daily cost breakdown exported by the cloud providers. This is a high-volume fact table.

| Field          | Type          | Description                   | Generation Rules / Realism                                                                                          |
| :------------- | :------------ | :---------------------------- | :------------------------------------------------------------------------------------------------------------------ |
| `billing_id`   | String (UUID) | Primary Key                   | Auto-generated ID.                                                                                                  |
| `date`         | Date          | The day the cost was incurred | Generated sequentially for the past 1-2 years.                                                                      |
| `resource_id`  | String (UUID) | Foreign Key                   | Reference to `finops_cloud_resources`.                                                                              |
| `cost_usd`     | Decimal       | Total cost for the day        | Base run-rate with simulated random spikes (e.g., a bad pipeline run causing compute costs to jump 500% for a day). |
| `usage_metric` | String        | How it was billed             | Compute Hours, TB Scanned, GB Stored.                                                                               |
| `usage_amount` | Decimal       | The raw usage number          | Correlates with `cost_usd`.                                                                                         |

### 3. `eng_incidents`

Records of system outages, data pipeline failures, or performance degradation alerts.

| Field                        | Type          | Description                | Generation Rules / Realism                                                         |
| :--------------------------- | :------------ | :------------------------- | :--------------------------------------------------------------------------------- |
| `incident_id`                | String (UUID) | Primary Key                | Auto-generated ID.                                                                 |
| `date`                       | Date          | When the incident occurred | Randomly distributed, perhaps slightly higher frequency during early startup days. |
| `severity`                   | String        | Impact level               | SEV-1 (Critical Outage), SEV-2 (Degraded Performance), SEV-3 (Minor Bug/Alert).    |
| `affected_resource_id`       | String (UUID) | Foreign Key                | Reference to `finops_cloud_resources` to identify what broke.                      |
| `time_to_resolution_minutes` | Integer       | How long it took to fix    | SEV-1s should be resolved faster (e.g., 30-120 mins), SEV-3s might take longer.    |
| `root_cause`                 | String        | Why it happened            | E.g., "Bad code deployment", "Upstream API failure", "Out of memory (OOM)".        |

---

## Snowfakery Implementation Notes

- **Static vs. Time-Series:** `finops_cloud_resources` will be generated as a relatively static dimension table (e.g., 50-100 core resources). `finops_daily_billing` requires a time-series loop generating 365+ records per resource.
- **Cost Scaling:** To make the data realistic, SaaS production database costs (like Snowflake) should slowly trend upwards month-over-month to simulate customer data growth, rather than remaining perfectly flat.
- **Correlations:** For advanced realism, we can attempt to tie spikes in `cost_usd` on specific days to `eng_incidents` (e.g., a runaway query causes a massive bill and triggers a SEV-2 alert).
