from __future__ import annotations

import csv
import os

OUTPUT_DIR = "setup/finops/data"
OUTPUT_FILE = f"{OUTPUT_DIR}/finops_cloud_resources.csv"

RESOURCES: list[dict[str, str | int | float]] = [
    # ENG resources (resource_id 1–14, ~56% share)
    {"resource_id": 1,  "resource_name": "eng-prod-eks-cluster",      "provider": "GCP",   "service_type": "Container",  "region": "asia-east1",     "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 2800.00},
    {"resource_id": 2,  "resource_name": "eng-prod-aks-cluster",      "provider": "Azure", "service_type": "Container",  "region": "eastasia",       "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 2400.00},
    {"resource_id": 3,  "resource_name": "eng-prod-rds-postgres",     "provider": "AWS",   "service_type": "Database",   "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 1800.00},
    {"resource_id": 4,  "resource_name": "eng-prod-ec2-api-servers",  "provider": "AWS",   "service_type": "Compute",    "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 1500.00},
    {"resource_id": 5,  "resource_name": "eng-prod-bigquery-dw",      "provider": "GCP",   "service_type": "Database",   "region": "asia-east1",     "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 1200.00},
    {"resource_id": 6,  "resource_name": "eng-prod-s3-data-lake",     "provider": "AWS",   "service_type": "Storage",    "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 900.00},
    {"resource_id": 7,  "resource_name": "eng-prod-cloudfront-cdn",   "provider": "AWS",   "service_type": "Compute",    "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 850.00},
    {"resource_id": 8,  "resource_name": "eng-staging-eks-cluster",   "provider": "GCP",   "service_type": "Container",  "region": "asia-east1",     "environment": "staging", "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 600.00},
    {"resource_id": 9,  "resource_name": "eng-staging-aks-cluster",   "provider": "Azure", "service_type": "Container",  "region": "eastasia",       "environment": "staging", "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 500.00},
    {"resource_id": 10, "resource_name": "eng-staging-rds-postgres",  "provider": "AWS",   "service_type": "Database",   "region": "ap-southeast-1", "environment": "staging", "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 400.00},
    {"resource_id": 11, "resource_name": "eng-dev-gke-sandbox",       "provider": "GCP",   "service_type": "Container",  "region": "asia-east1",     "environment": "dev",     "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 200.00},
    {"resource_id": 12, "resource_name": "eng-dev-ec2-dev-boxes",     "provider": "AWS",   "service_type": "Compute",    "region": "ap-southeast-2", "environment": "dev",     "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 150.00},
    {"resource_id": 13, "resource_name": "eng-dev-blob-storage",      "provider": "Azure", "service_type": "Storage",    "region": "eastasia",       "environment": "dev",     "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 100.00},
    {"resource_id": 14, "resource_name": "eng-prod-cloud-run-jobs",   "provider": "GCP",   "service_type": "Serverless", "region": "asia-east1",     "environment": "prod",    "department_id": "DEPT-ENG",   "cost_center": "CC-ENG-002",   "monthly_base_cost": 1100.00},
    # PS resources (resource_id 15–19)
    {"resource_id": 15, "resource_name": "ps-analytics-rds",          "provider": "AWS",   "service_type": "Database",   "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-PS",    "cost_center": "CC-PS-001",    "monthly_base_cost": 700.00},
    {"resource_id": 16, "resource_name": "ps-client-blob-storage",    "provider": "Azure", "service_type": "Storage",    "region": "eastasia",       "environment": "prod",    "department_id": "DEPT-PS",    "cost_center": "CC-PS-001",    "monthly_base_cost": 300.00},
    {"resource_id": 17, "resource_name": "ps-cloud-run-reporting",    "provider": "GCP",   "service_type": "Serverless", "region": "asia-east1",     "environment": "prod",    "department_id": "DEPT-PS",    "cost_center": "CC-PS-001",    "monthly_base_cost": 450.00},
    {"resource_id": 18, "resource_name": "ps-staging-analytics-rds",  "provider": "AWS",   "service_type": "Database",   "region": "ap-southeast-2", "environment": "staging", "department_id": "DEPT-PS",    "cost_center": "CC-PS-001",    "monthly_base_cost": 250.00},
    {"resource_id": 19, "resource_name": "ps-dev-sandbox-vm",         "provider": "Azure", "service_type": "Compute",    "region": "eastasia",       "environment": "dev",     "department_id": "DEPT-PS",    "cost_center": "CC-PS-001",    "monthly_base_cost": 120.00},
    # FIN resources (resource_id 20–22)
    {"resource_id": 20, "resource_name": "fin-bi-reporting-vm",       "provider": "Azure", "service_type": "Compute",    "region": "eastasia",       "environment": "prod",    "department_id": "DEPT-FIN",   "cost_center": "CC-FIN-005",   "monthly_base_cost": 350.00},
    {"resource_id": 21, "resource_name": "fin-s3-reports-archive",    "provider": "AWS",   "service_type": "Storage",    "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-FIN",   "cost_center": "CC-FIN-005",   "monthly_base_cost": 180.00},
    {"resource_id": 22, "resource_name": "fin-bigquery-analytics",    "provider": "GCP",   "service_type": "Database",   "region": "asia-east1",     "environment": "prod",    "department_id": "DEPT-FIN",   "cost_center": "CC-FIN-005",   "monthly_base_cost": 420.00},
    # SALES resources (resource_id 23–24)
    {"resource_id": 23, "resource_name": "sales-crm-lambda",          "provider": "AWS",   "service_type": "Serverless", "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-SALES", "cost_center": "CC-SALES-003", "monthly_base_cost": 220.00},
    {"resource_id": 24, "resource_name": "sales-demo-vm",             "provider": "Azure", "service_type": "Compute",    "region": "eastasia",       "environment": "dev",     "department_id": "DEPT-SALES", "cost_center": "CC-SALES-003", "monthly_base_cost": 90.00},
    # HR resources (resource_id 25)
    {"resource_id": 25, "resource_name": "hr-hris-storage",           "provider": "AWS",   "service_type": "Storage",    "region": "ap-southeast-1", "environment": "prod",    "department_id": "DEPT-HR",    "cost_center": "CC-HR-004",    "monthly_base_cost": 160.00},
]

FIELDNAMES = [
    "resource_id",
    "resource_name",
    "provider",
    "service_type",
    "region",
    "environment",
    "department_id",
    "cost_center",
    "monthly_base_cost",
]


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(RESOURCES)
    print(f"Written {len(RESOURCES)} resources to {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
