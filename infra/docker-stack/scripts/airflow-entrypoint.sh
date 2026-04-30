#!/usr/bin/env bash
# Injects VAULT_TOKEN from the vault_airflow_token Docker secret so that
# the HashiCorp Vault secrets backend can authenticate to Vault.
set -euo pipefail

export VAULT_TOKEN="$(cat /run/secrets/vault_airflow_token)"
exec /usr/bin/dumb-init -- /entrypoint "$@"
