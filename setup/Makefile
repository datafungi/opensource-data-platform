.PHONY: help \
        sf-purge sf-generate sf-enrich sf-load sf-analyze-year1 sf-full-refresh \
        hr-generate \
        ops-generate \
        finops-generate all-generate

TARGET_ORG ?= dev-org
START_DATE ?= 2024-04-16
END_DATE   ?= 2025-04-16

help:
	@echo "Synthetic data setup workflow"
	@echo ""
	@echo "Salesforce targets:"
	@echo "  make sf-purge TARGET_ORG=dev-org              - Delete Opportunity, Contact, Account data"
	@echo "  make sf-generate                              - Generate CSVs from Snowfakery recipe"
	@echo "  make sf-enrich                                - Populate analytics custom fields in CSVs"
	@echo "  make sf-load                                  - Load CSVs into Salesforce"
	@echo "  make sf-analyze-year1 TARGET_ORG=dev-org START_DATE=YYYY-MM-DD END_DATE=YYYY-MM-DD"
	@echo "                                                - Stage-level year window summary"
	@echo "  make sf-full-refresh TARGET_ORG=dev-org       - Purge, generate, enrich, load"
	@echo ""
	@echo "HR targets:"
	@echo "  make hr-generate                              - Generate HR CSVs and enrich hierarchy"
	@echo ""
	@echo "Ops targets:"
	@echo "  make ops-generate                             - Generate Ops CSVs (projects, allocations, timesheets)"
	@echo ""
	@echo "FinOps targets:"
	@echo "  make finops-generate                              - Generate FinOps CSVs (cloud resources, billing, incidents)"
	@echo ""
	@echo "Unified targets:"
	@echo "  make all-generate                                 - Run full pipeline: HR → Ops → FinOps → copy to data/landing/"

sf-purge:
	uv run --project . python salesforce/scripts/purge_sales_data.py --target-org $(TARGET_ORG) --yes

sf-generate:
	uv run --project . snowfakery salesforce/recipes/sales_pipeline.yml --output-format csv --output-folder salesforce/data

sf-enrich:
	uv run --project . python salesforce/scripts/enrich_sales_pipeline_csv.py

sf-load:
	uv run --project . python salesforce/scripts/load_sales_pipeline.py

sf-analyze-year1:
	sf data query --target-org $(TARGET_ORG) --query "SELECT StageName, COUNT(Id) opps, SUM(Amount) totalAmount, AVG(Probability) avgProbability FROM Opportunity WHERE CloseDate >= $(START_DATE) AND CloseDate < $(END_DATE) GROUP BY StageName ORDER BY SUM(Amount) DESC"

sf-full-refresh: sf-purge sf-generate sf-enrich sf-load

hr-generate:
	bash hr/generate.sh

ops-generate:
	bash ops/generate.sh

finops-generate:
	bash finops/generate.sh

all-generate:
	bash generate.sh
