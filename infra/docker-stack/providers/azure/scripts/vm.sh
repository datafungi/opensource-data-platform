#!/usr/bin/env bash
# Manage Azure cluster VMs: start, stop, check status, or SSH in.
set -euo pipefail

DEFAULT_RESOURCE_GROUP="data-platform-dev-platform-rg"
DEFAULT_ADMIN_USERNAME="azureuser"

usage() {
  local default_prefix="${DEFAULT_RESOURCE_GROUP%-platform-rg}"
  cat >&2 <<EOF
Usage: $(basename "$0") <start|stop|status|ssh> [options]

Commands:
  start    Start (allocate) the specified VMs
  stop     Deallocate the specified VMs (compute billing stops; disks and IPs retained)
  status   Show power state of VMs in the resource group
  ssh      Open an SSH session to a VM

Targeting (required for start/stop/ssh; optional for status, defaults to --all):
  -a,  --all                       Target all VMs in the resource group (not valid for ssh)
  -vm, --virtual-machine <name>    Target a VM by name (repeatable for start/stop/status)

Options:
  -rg, --resource-group <name>     Resource group (default: $DEFAULT_RESOURCE_GROUP)
  -w,  --wait                      Wait until VMs reach the target state, then print a
                                   summary table (start/stop only)

SSH options:
  -i,  --identity-file <path>      SSH private key (default: ~/.ssh/${default_prefix}.pem)
  -u,  --user <username>           SSH login user (default: $DEFAULT_ADMIN_USERNAME)
  Extra args after -- are forwarded verbatim to ssh (e.g. -- docker ps)

Examples:
  $(basename "$0") stop  --all
  $(basename "$0") stop  --all --wait
  $(basename "$0") start --all --resource-group my-platform-rg
  $(basename "$0") stop  -vm data-platform-dev-node-2
  $(basename "$0") start -vm data-platform-dev-node-1 -vm data-platform-dev-node-3 --wait
  $(basename "$0") status
  $(basename "$0") status -vm data-platform-dev-node-1
  $(basename "$0") ssh   -vm data-platform-dev-node-1
  $(basename "$0") ssh   -vm data-platform-dev-node-1 -i ~/.ssh/my-key.pem -u admin
  $(basename "$0") ssh   -vm data-platform-dev-node-1 -- docker ps
EOF
  exit 1
}

[[ $# -eq 0 ]] && usage

COMMAND="$1"; shift
[[ "$COMMAND" != "start" && "$COMMAND" != "stop" && "$COMMAND" != "status" && "$COMMAND" != "ssh" ]] && {
  echo "Error: command must be 'start', 'stop', 'status', or 'ssh'" >&2; usage
}

RESOURCE_GROUP="$DEFAULT_RESOURCE_GROUP"
TARGET_ALL=false
TARGET_VMS=()
WAIT=false
IDENTITY_FILE=""
SSH_USER="$DEFAULT_ADMIN_USERNAME"
SSH_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift; SSH_EXTRA_ARGS=("$@"); break ;;
    -a|--all)
      TARGET_ALL=true; shift ;;
    -vm|--virtual-machine)
      [[ -z "${2:-}" ]] && { echo "Error: --virtual-machine requires a VM name" >&2; exit 1; }
      TARGET_VMS+=("$2"); shift 2 ;;
    -rg|--resource-group)
      [[ -z "${2:-}" ]] && { echo "Error: --resource-group requires a name" >&2; exit 1; }
      RESOURCE_GROUP="$2"; shift 2 ;;
    -w|--wait)
      WAIT=true; shift ;;
    -i|--identity-file)
      [[ -z "${2:-}" ]] && { echo "Error: --identity-file requires a path" >&2; exit 1; }
      IDENTITY_FILE="$2"; shift 2 ;;
    -u|--user)
      [[ -z "${2:-}" ]] && { echo "Error: --user requires a username" >&2; exit 1; }
      SSH_USER="$2"; shift 2 ;;
    *) echo "Error: unknown option '$1'" >&2; usage ;;
  esac
done

# ── Validate flags ────────────────────────────────────────────────────────────

if [[ "$TARGET_ALL" == true && ${#TARGET_VMS[@]} -gt 0 ]]; then
  echo "Error: --all and --virtual-machine are mutually exclusive" >&2; usage
fi

if [[ "$COMMAND" == "ssh" ]]; then
  [[ "$TARGET_ALL" == true ]] && { echo "Error: --all is not valid for 'ssh'" >&2; usage; }
  [[ ${#TARGET_VMS[@]} -ne 1 ]] && { echo "Error: 'ssh' requires exactly one --virtual-machine" >&2; usage; }
fi

if [[ "$COMMAND" != "status" && "$COMMAND" != "ssh" && "$TARGET_ALL" == false && ${#TARGET_VMS[@]} -eq 0 ]]; then
  echo "Error: specify --all or at least one --virtual-machine" >&2; usage
fi

if [[ "$WAIT" == true && "$COMMAND" != "start" && "$COMMAND" != "stop" ]]; then
  echo "Error: --wait is only valid with start or stop" >&2; usage
fi

if [[ ${#SSH_EXTRA_ARGS[@]} -gt 0 && "$COMMAND" != "ssh" ]]; then
  echo "Error: -- extra args are only valid with ssh" >&2; usage
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

resolve_all_vms() {
  mapfile -t TARGET_VMS < <(az vm list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[].name" -o tsv)
  if [[ ${#TARGET_VMS[@]} -eq 0 ]]; then
    echo "No VMs found in resource group '$RESOURCE_GROUP'" >&2; exit 1
  fi
}

validate_named_vms() {
  for vm in "${TARGET_VMS[@]}"; do
    az vm show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$vm" \
      --query id -o tsv &>/dev/null || {
      echo "Error: VM '$vm' not found in resource group '$RESOURCE_GROUP'" >&2; exit 1
    }
  done
}

build_vm_ids() {
  VM_IDS=()
  for vm in "${TARGET_VMS[@]}"; do
    VM_IDS+=("$(az vm show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$vm" \
      --query id -o tsv)")
  done
}

show_status_table() {
  local query
  if [[ ${#TARGET_VMS[@]} -eq 0 ]]; then
    query="[].{Name:name, State:powerState, Size:hardwareProfile.vmSize}"
  else
    local filter=""
    for vm in "${TARGET_VMS[@]}"; do
      filter="${filter:+$filter || }name=='$vm'"
    done
    query="[?$filter].{Name:name, State:powerState, Size:hardwareProfile.vmSize}"
  fi

  az vm list \
    --resource-group "$RESOURCE_GROUP" \
    --show-details \
    --query "$query" \
    -o table
}

wait_for_vms() {
  local flag="$1"
  echo ""
  echo "Waiting for VMs to reach target state..."
  local pids=()
  for vm in "${TARGET_VMS[@]}"; do
    az vm wait --resource-group "$RESOURCE_GROUP" --name "$vm" "$flag" &
    pids+=($!)
  done
  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  [[ "$failed" -ne 0 ]] && { echo "Error: one or more VMs did not reach the target state" >&2; exit 1; }
}

# ── SSH ───────────────────────────────────────────────────────────────────────

if [[ "$COMMAND" == "ssh" ]]; then
  local_vm="${TARGET_VMS[0]}"

  # Derive default key from resource group: strip -platform-rg suffix
  name_prefix="${RESOURCE_GROUP%-platform-rg}"
  identity_file="${IDENTITY_FILE:-$HOME/.ssh/${name_prefix}.pem}"

  if [[ ! -f "$identity_file" ]]; then
    echo "Error: SSH key not found at '$identity_file'" >&2
    echo "Specify a key with --identity-file / -i" >&2
    exit 1
  fi

  ip=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$local_vm" \
    --show-details \
    --query privateIps -o tsv)

  [[ -z "$ip" ]] && { echo "Error: could not resolve private IP for '$local_vm'" >&2; exit 1; }

  echo "→ ssh -i $identity_file ${SSH_USER}@${ip}${SSH_EXTRA_ARGS[*]:+ ${SSH_EXTRA_ARGS[*]}}"
  exec ssh -i "$identity_file" "${SSH_USER}@${ip}" "${SSH_EXTRA_ARGS[@]+"${SSH_EXTRA_ARGS[@]}"}"
fi

# ── Status ────────────────────────────────────────────────────────────────────

if [[ "$COMMAND" == "status" ]]; then
  [[ "$TARGET_ALL" == true ]] && TARGET_VMS=()
  [[ ${#TARGET_VMS[@]} -gt 0 ]] && validate_named_vms
  echo "Resource group: $RESOURCE_GROUP"
  echo ""
  show_status_table
  exit 0
fi

# ── Start / Stop ──────────────────────────────────────────────────────────────

[[ "$TARGET_ALL" == true ]] && resolve_all_vms
[[ "$TARGET_ALL" == false ]] && validate_named_vms
build_vm_ids

echo "Resource group : $RESOURCE_GROUP"
printf "VMs            : %s\n" "${TARGET_VMS[@]}"
echo ""

if [[ "$COMMAND" == "stop" ]]; then
  echo "Deallocating..."
  az vm deallocate --ids "${VM_IDS[@]}" --no-wait
  echo "Deallocation requested."
  WAIT_FLAG="--deallocated"
else
  echo "Starting..."
  az vm start --ids "${VM_IDS[@]}" --no-wait
  echo "Start requested."
  WAIT_FLAG="--running"
fi

if [[ "$WAIT" == true ]]; then
  wait_for_vms "$WAIT_FLAG"
  echo ""
  echo "Summary:"
  show_status_table
else
  echo ""
  echo "To wait for completion:"
  for vm in "${TARGET_VMS[@]}"; do
    echo "  az vm wait --resource-group $RESOURCE_GROUP --name $vm $WAIT_FLAG"
  done
fi
