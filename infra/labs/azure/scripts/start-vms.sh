#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-datafungi-lab}"
if [[ "$#" -gt 0 ]]; then
  VMS=("$@")
else
  VMS=("vm-01-control" "vm-02-worker-a" "vm-03-worker-b")
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI is required but was not found in PATH." >&2
  exit 1
fi

echo "Starting VMs in resource group: ${RESOURCE_GROUP}"

for vm in "${VMS[@]}"; do
  echo "Starting ${vm}..."
  az vm start \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${vm}" \
    --no-wait
done

echo "Start requests submitted."
echo "Check status with: az vm list -g ${RESOURCE_GROUP} -d --output table"
