#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_PATH="${PROJECT_ROOT}/setup/salesforce/.venv"
RECIPE_DIR="${SCRIPT_DIR}"
OUTPUT_DIR="${PROJECT_ROOT}/data/landing/hr"

echo "=== HR Data Generation ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Output dir:   ${OUTPUT_DIR}"

# Activate Snowfakery venv
# shellcheck source=/dev/null
source "${VENV_PATH}/bin/activate"

# Run Snowfakery recipe (must run from setup/hr so relative output path resolves)
cd "${RECIPE_DIR}"
snowfakery recipes/hr_generation.yml \
  --output-format csv \
  --output-folder "${OUTPUT_DIR}"

# Run post-processing event script (uses DATA_DIR derived from script location)
cd "${PROJECT_ROOT}"
python setup/hr/scripts/generate_events.py

echo ""
echo "=== Output files ==="
for f in "${OUTPUT_DIR}"/*.csv; do
  count=$(( $(wc -l < "${f}") - 1 ))
  echo "  ${f##*/}: ${count} records"
done
echo "=== Done ==="
