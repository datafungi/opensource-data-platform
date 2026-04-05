#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LANDING="$REPO_ROOT/data/landing"

echo "======================================"
echo " Synthetic Data Generation Pipeline"
echo "======================================"

echo ""
echo "--- Phase 1: HR & Talent Data ---"
bash "$SCRIPT_DIR/hr/generate.sh"

echo ""
echo "--- Phase 2: Operations & Projects ---"
bash "$SCRIPT_DIR/ops/generate.sh"

echo ""
echo "--- Phase 3: FinOps & Incidents ---"
bash "$SCRIPT_DIR/finops/generate.sh"

echo ""
echo "--- Copying to data/landing/ ---"
mkdir -p "$LANDING"

find "$SCRIPT_DIR" -name "*.csv" -path "*/data/*" | while read -r f; do
  cp "$f" "$LANDING/"
  echo "  Copied: $(basename "$f")"
done

echo ""
echo "======================================"
echo " All CSV files in data/landing/:"
ls -1 "$LANDING/"
echo "======================================"
echo ""
echo "NOTE: To assign Salesforce account owners, run manually:"
echo "  sf project deploy start --source-dir setup/salesforce/force-app"
echo "  uv run python setup/salesforce/scripts/assign_account_owners.py"
