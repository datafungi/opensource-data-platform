#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_multipass() {
  command -v multipass &>/dev/null || die "multipass is not installed"
}

resolve_template() {
  local name="$1"
  local path="$TEMPLATES_DIR/${name}.yaml"
  [[ -f "$path" ]] || die "template '${name}' not found in $TEMPLATES_DIR"
  echo "$path"
}

# Expand a '*' glob against running instance names; return literal name otherwise.
expand_pattern() {
  local pattern="$1"
  if [[ "$pattern" == *"*"* ]]; then
    multipass list --format csv \
      | tail -n +2 \
      | cut -d',' -f1 \
      | grep -E "^${pattern//\*/.*}$" \
      || true
  else
    echo "$pattern"
  fi
}

# ── commands ──────────────────────────────────────────────────────────────────

cmd_launch() {
  require_multipass
  local template="" name="" count=1
  local cpu="" memory="" disk=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template|-t) template="$2"; shift 2 ;;
      --name|-n)     name="$2";     shift 2 ;;
      --count|-c)    count="$2";    shift 2 ;;
      --cpu)         cpu="$2";      shift 2 ;;
      --memory|-m)   memory="$2";   shift 2 ;;
      --disk|-d)     disk="$2";     shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  [[ -n "$template" ]] || die "--template is required"
  local cloud_init
  cloud_init="$(resolve_template "$template")"

  local res_flags=()
  [[ -n "$cpu"    ]] && res_flags+=(--cpus   "$cpu")
  [[ -n "$memory" ]] && res_flags+=(--memory "$memory")
  [[ -n "$disk"   ]] && res_flags+=(--disk   "$disk")

  [[ -n "$name" ]] || name="$template"

  if [[ "$count" -eq 1 ]]; then
    info "Launching '$name' from template '$template'"
    multipass launch --name "$name" --cloud-init "$cloud_init" \
      "${res_flags[@]+"${res_flags[@]}"}"
  else
    info "Launching $count instances from template '$template' (prefix: $name)"
    for i in $(seq 1 "$count"); do
      info "  launching '${name}-${i}'"
      multipass launch --name "${name}-${i}" --cloud-init "$cloud_init" \
        "${res_flags[@]+"${res_flags[@]}"}"
    done
  fi
}

cmd_stop() {
  require_multipass
  [[ $# -gt 0 ]] || die "usage: stop <name|pattern> ..."
  for pattern in "$@"; do
    while IFS= read -r instance; do
      [[ -n "$instance" ]] || continue
      info "Stopping '$instance'"
      multipass stop "$instance"
    done < <(expand_pattern "$pattern")
  done
}

cmd_delete() {
  require_multipass
  local purge=false
  local names=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge|-p) purge=true; shift ;;
      *)          names+=("$1"); shift ;;
    esac
  done

  [[ ${#names[@]} -gt 0 ]] || die "usage: delete [--purge] <name|pattern> ..."

  for pattern in "${names[@]}"; do
    while IFS= read -r instance; do
      [[ -n "$instance" ]] || continue
      info "Deleting '$instance'"
      multipass delete "$instance"
    done < <(expand_pattern "$pattern")
  done

  $purge && { info "Purging deleted instances"; multipass purge; }
}

cmd_help() {
  cat <<'EOF'
Usage: script.sh <command> [options]

Commands:
  launch  --template <name>     Launch one or more instances
            --name    <prefix>  Instance name / prefix (default: template name)
            --count   <n>       Number of instances (default: 1)
            --cpu     <n>       vCPUs
            --memory  <size>    RAM  (e.g. 2G)
            --disk    <size>    Disk (e.g. 20G)
  stop    <name|pattern> ...    Stop instances
  delete  [--purge] <name|pat>  Delete (and optionally purge) instances
  help                          Show this help

Patterns:
  A '*' wildcard is matched against existing instance names.
  Example: delete --purge worker-*  →  deletes worker-1, worker-2, …

Examples:
  ./script.sh launch --template docker --name worker --count 3 --cpu 2 --memory 4G
  ./script.sh stop worker-*
  ./script.sh delete --purge worker-*
EOF
}

# ── entry point ───────────────────────────────────────────────────────────────

[[ $# -gt 0 ]] || { cmd_help; exit 0; }

command="$1"; shift
case "$command" in
  launch)           cmd_launch "$@" ;;
  stop)             cmd_stop "$@" ;;
  delete|rm|remove) cmd_delete "$@" ;;
  help|--help|-h)   cmd_help ;;
  *) die "unknown command '$command'. Run '$0 help' for usage." ;;
esac
