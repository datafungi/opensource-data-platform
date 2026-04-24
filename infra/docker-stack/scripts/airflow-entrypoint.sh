#!/usr/bin/env bash
# Injects AZURE_CLIENT_ID from the azure_mi_client_id Docker secret so that
# DefaultAzureCredential can identify the correct user-assigned managed identity
# when multiple identities are attached to the VM.
set -euo pipefail

export AZURE_CLIENT_ID="$(cat /run/secrets/azure_mi_client_id)"
exec /usr/bin/dumb-init -- /entrypoint "$@"
