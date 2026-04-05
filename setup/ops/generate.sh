#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VENV_PATH="${PROJECT_ROOT}/setup/.venv"
OUTPUT_DIR="${SCRIPT_DIR}/data"

echo "=== Ops Data Generation ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Output dir:   ${OUTPUT_DIR}"

# Validate upstream CSVs exist before activating venv
for f in \
    "${PROJECT_ROOT}/setup/salesforce/data/Opportunity.csv" \
    "${PROJECT_ROOT}/setup/salesforce/data/Account.csv" \
    "${PROJECT_ROOT}/setup/hr/data/hr_employees.csv"; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: Required upstream file not found: ${f}" >&2
    exit 1
  fi
done

# Activate shared setup venv (duckdb available)
# shellcheck source=/dev/null
source "${VENV_PATH}/bin/activate"

mkdir -p "${OUTPUT_DIR}"

# Run generation scripts in dependency order
python "${SCRIPT_DIR}/scripts/generate_projects.py"
python "${SCRIPT_DIR}/scripts/generate_allocations.py"
python "${SCRIPT_DIR}/scripts/generate_timesheets.py"

echo ""
echo "=== Output files ==="
for f in "${OUTPUT_DIR}"/*.csv; do
  count=$(( $(wc -l < "${f}") - 1 ))
  echo "  ${f##*/}: ${count} records"
done
echo "=== Done ==="
