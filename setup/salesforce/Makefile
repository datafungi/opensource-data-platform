.PHONY: help purge generate enrich load analyze-year1 full-refresh

TARGET_ORG ?= dev-org
START_DATE ?= 2024-04-16
END_DATE ?= 2025-04-16

help:
	@echo "Salesforce synthetic data workflow"
	@echo ""
	@echo "Targets:"
	@echo "  make purge TARGET_ORG=dev-org         - Delete Opportunity, Contact, Account data"
	@echo "  make generate                         - Generate CSVs from Snowfakery recipe"
	@echo "  make enrich                           - Populate analytics custom fields in CSVs"
	@echo "  make load                             - Load CSVs into Salesforce"
	@echo "  make analyze-year1 TARGET_ORG=dev-org START_DATE=YYYY-MM-DD END_DATE=YYYY-MM-DD"
	@echo "                                        - Example stage-level year window summary"
	@echo "  make full-refresh TARGET_ORG=dev-org  - Purge, generate, enrich, load"

purge:
	uv run python scripts/purge_sales_data.py --target-org $(TARGET_ORG) --yes

generate:
	uv run snowfakery recipes/sales_pipeline.yml --output-format csv --output-folder data

enrich:
	uv run python scripts/enrich_sales_pipeline_csv.py

load:
	uv run python scripts/load_sales_pipeline.py

analyze-year1:
	sf data query --target-org $(TARGET_ORG) --query "SELECT StageName, COUNT(Id) opps, SUM(Amount) totalAmount, AVG(Probability) avgProbability FROM Opportunity WHERE CloseDate >= $(START_DATE) AND CloseDate < $(END_DATE) GROUP BY StageName ORDER BY SUM(Amount) DESC"

full-refresh: purge generate enrich load
