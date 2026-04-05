#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_PATH="${PROJECT_ROOT}/setup/.venv"
OUTPUT_DIR="${SCRIPT_DIR}/data"

echo "=== FinOps Data Generation ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Output dir:   ${OUTPUT_DIR}"

# Validate ops upstream CSV (needed by generate_billing.py)
if [[ ! -f "${PROJECT_ROOT}/setup/ops/data/ops_projects.csv" ]]; then
  echo "ERROR: Required upstream file not found: ${PROJECT_ROOT}/setup/ops/data/ops_projects.csv" >&2
  echo "       Run ops-generate first." >&2
  exit 1
fi

# Activate shared setup venv (duckdb available)
# shellcheck source=/dev/null
source "${VENV_PATH}/bin/activate"

mkdir -p "${OUTPUT_DIR}"

# Run generation scripts in dependency order
python "${SCRIPT_DIR}/scripts/generate_resources.py"
python "${SCRIPT_DIR}/scripts/generate_billing.py"
python "${SCRIPT_DIR}/scripts/generate_incidents.py"

echo ""
echo "=== Output files ==="
for f in "${OUTPUT_DIR}"/*.csv; do
  count=$(( $(wc -l < "${f}") - 1 ))
  echo "  ${f##*/}: ${count} records"
done
echo "=== Done ==="
