# Data Contracts

This directory contains data contracts written in the
[Open Data Contract Standard (ODCS)](https://bitol-io.github.io/open-data-contract-standard/)
v3.1.0.

## What is a Data Contract?

A data contract is a versioned, human- and machine-readable agreement between a data
producer and its consumers. It defines:

- **Schema** — column names, types, nullability, primary keys
- **Quality rules** — freshness, completeness, validity checks (expressed in SodaCL)
- **Terms of use** — who can use this data and for what purpose
- **Service levels** — availability and freshness SLAs

## File Structure

```
data-contracts/
├── README.md
├── orders_contract.yaml      # Orders fact table (fct_orders in ClickHouse)
└── ...                       # Add one file per dataset
```

## Contract Schema

Each contract follows the ODCS specification. Key top-level fields:

| Field                       | Purpose                                            |
|-----------------------------|----------------------------------------------------|
| `dataContractSpecification` | Spec version (pin to avoid breaking changes)       |
| `id`                        | URN-style unique identifier                        |
| `info`                      | Title, version, owner, contact                     |
| `servers`                   | Where the data lives (host, database, schema)      |
| `terms`                     | Usage rights and limitations                       |
| `models`                    | Table/field definitions with types and constraints |
| `quality`                   | SodaCL checks embedded inline                      |
| `servicelevels`             | Availability and freshness SLAs                    |

## Validation

Contracts are validated via the `ODCSOperator` from the `airflow-provider-odcs`
custom provider (`airflow/dags/plugins/providers/odcs/`). It reads each contract, extracts
the embedded SodaCL checks, and runs them against the declared data source.

A failed check raises an `AirflowException` and the DAG task turns red — this is the
signal that the producer must investigate and fix the data or update the contract.

## Adding a New Contract

1. Create `data-contracts/<dataset_name>_contract.yaml` following the ODCS spec.
2. Embed SodaCL quality checks in the `quality.specification` block.
3. Add a corresponding Soda data source entry in `soda/configuration.yml`.
4. The `odcs_validation_dag` picks up new files automatically (it scans the directory).

## Validating Locally

```bash
# Requires: soda-core-clickhouse installed (see pyproject.toml)
export CLICKHOUSE_USER=default
export CLICKHOUSE_PASSWORD=YourStrong\!Passw0rd

# The ODCSOperator extracts quality.specification and runs it via soda scan.
# You can do the same manually:
python3 - <<'EOF'
import yaml, tempfile, subprocess, pathlib

contract = yaml.safe_load(pathlib.Path("data-contracts/orders_contract.yaml").read_text())
checks = yaml.dump(contract["quality"]["specification"])

with tempfile.NamedTemporaryFile(suffix=".yml", mode="w", delete=False) as f:
    f.write(checks)
    checks_file = f.name

subprocess.run(
    ["soda", "scan", "-d", "orders_clickhouse", "-c", "soda/configuration.yml", checks_file],
    check=True,
)
EOF
```
