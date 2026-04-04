# Salesforce Setup

This folder contains Snowfakery data generation, Salesforce metadata, and scripts for loading/analyzing synthetic sales data.

## Structure

- `recipes/`: Snowfakery recipes
- `data/`: generated CSV output files
- `scripts/`: auth, purge, enrichment, and load scripts
- `force-app/`: Salesforce metadata (custom fields, permission sets)
- `docs/`: analysis/query references
- `sfdx-project.json`: Salesforce DX project config

## Typical Workflow

From `setup/salesforce` you can run:

```bash
uv sync
make help
```

1. (Optional) purge existing synthetic data:

```bash
make purge TARGET_ORG=dev-org
```

2. Generate base CSVs from Snowfakery recipe:

```bash
make generate
```

3. Enrich CSVs with custom analytics fields:

```bash
make enrich
```

4. Load CSVs into Salesforce:

```bash
make load
```

5. Run analysis queries:

- See `setup/salesforce/docs/PIPELINE_ANALYTICS_PLAYBOOK.md`

## One-command reset and reload

```bash
make full-refresh TARGET_ORG=dev-org
```
