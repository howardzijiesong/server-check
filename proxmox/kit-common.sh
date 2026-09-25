#!/usr/bin/env bash
# =============================================================================
# kit-common.sh - shared logging + error-checking helpers for the Proxmox scripts.
# Sourced by pve-audit.sh, pve-bench.sh and pve-monitor.sh; not meant to be run.
#
# Every run writes two files into its results folder:
#   <script>-<host>-<timestamp>.txt    human-readable log (everything shown on screen)
#   <script>-<host>-<timestamp>.jsonl  machine log: one JSON record per finding, fact,
#                                      metric or error - read by Analyze-Results.ps1
# Record levels: START END OK INFO WARN ERROR FACT METRIC
# =============================================================================
# shellcheck disable=SC2034   # variables here are used by the sourcing scripts

KIT_VERSION="2026.09.25"
KIT_ERRORS=0
KIT_CAT="run"
KIT_JSONL=""

have() { command -v "$1" >/dev/null 2>&1; }

kit_json() { # escape a string for JSON
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/}; s=${s//$'\n'/\\n}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

kit_rec() { # level category key message [value] [unit]
  [[ -n "$KIT_JSONL" ]] || return 0
  printf '{"ts":"%s","script":"%s","ver":"%s","host":"%s","level":"%s","cat":"%s","key":"%s","msg":"%s","value":"%s","unit":"%s"}\n' \
    "$(date -Is)" "$KIT_SCRIPT" "$KIT_VERSION" "$KIT_HOST" "$1" "$(kit_json "$2")" "$(kit_json "$3")" \
    "$(kit_json "$4")" "$(kit_json "${5:-}")" "$(kit_json "${6:-}")" >> "$KIT_JSONL" 2>/dev/null
}
kit_fact()   { kit_rec FACT "$KIT_CAT" "$1" "${3:-}" "$2"; }          # key value [message]
kit_metric() { kit_rec METRIC "$KIT_CAT" "$1" "${4:-}" "$2" "${3:-}"; } # key value [unit] [message]

kit_error() { # message [hint]
  KIT_ERRORS=$((KIT_ERRORS + 1))
  echo "ERROR: $1"
  [[ -n "${2:-}" ]] && echo "  hint: $2"
  kit_rec ERROR "$KIT_CAT" error "$1${2:+ | hint: $2}"
}
kit_die() { kit_error "$@"; exit 1; }

kit_section() { # sets the category used for the following records
  KIT_CAT=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | cut -c1-40)
  printf '\n==================== %s ====================\n' "$1"
}

kit_init() { # <script-name> <output-dir> [original args...]
  KIT_SCRIPT=$1; local out=$2; shift 2
  if ! mkdir -p "$out" 2>/dev/null || ! touch "$out/.kit-write-test" 2>/dev/null; then
    echo "ERROR: cannot write to $out"
    echo "  hint: the kit is probably on read-only media. Copy it to the host first: scp -r proxmox root@<host>:/root/kit/"
    exit 2
  fi
  rm -f "$out/.kit-write-test"
  KIT_OUT=$out
  KIT_HOST=$(hostname -s 2>/dev/null || hostname)
  KIT_TS=$(date +%Y%m%d-%H%M%S)
  KIT_BASE="$KIT_OUT/${KIT_SCRIPT}-${KIT_HOST}-${KIT_TS}"
  KIT_JSONL="$KIT_BASE.jsonl"
  KIT_LOG="$KIT_BASE.txt"
  KIT_START=$(date +%s)
  : > "$KIT_JSONL"
  exec > >(trap '' INT TERM; exec tee -a "$KIT_LOG") 2>&1
  kit_rec START run args "$*"
  kit_rec FACT host pve_version "" "$(pveversion 2>/dev/null | head -1)"
  kit_rec FACT host kernel "" "$(uname -r)"
  trap kit__on_exit EXIT
}

kit__on_exit() {
  local rc=$?
  if declare -F kit_cleanup >/dev/null; then kit_cleanup; fi
  kit_rec END run status "rc=$rc errors=$KIT_ERRORS duration=$(( $(date +%s) - KIT_START ))s" "$rc"
  echo
  echo "Human log:   $KIT_LOG"
  echo "Machine log: $KIT_JSONL"
  echo "Analyze all results later with:  pwsh ./Analyze-Results.ps1 -Path <results folder(s)>"
  if (( KIT_ERRORS > 0 )); then echo "$KIT_ERRORS error(s) were logged - search the log for 'ERROR:' and 'hint:'."; fi
  sleep 0.3   # let tee flush
}

# ------------------------------------------------------------- preflight checks
kit_require_root() {
  [[ $EUID -eq 0 ]] || kit_die "must run as root" "log in as root (Proxmox web shell or ssh root@<host>), or prefix the command with sudo"
}
kit_require_pve() {
  { have qm && have pvesm; } || kit_die "qm/pvesm not found - this is not a Proxmox VE host" "run the proxmox/ scripts on the Proxmox host itself"
}
kit_require_vm() {
  [[ "$1" =~ ^[0-9]+$ ]] || kit_die "VMID '$1' is not a number" "use the numeric ID from: qm list"
  qm config "$1" >/dev/null 2>&1 || kit_die "VM $1 not found on this node" "list VMs with 'qm list'; in a cluster run the script on the node hosting the VM"
}
kit_require_pool() {
  zpool list -H -o name "$1" >/dev/null 2>&1 || kit_die "ZFS pool '$1' not found" "pool names are case-sensitive (e.g. FastPool); list them with: zpool list"
}
kit_pool_busy() { zpool status "$1" 2>/dev/null | grep -qE 'scrub in progress|resilver in progress|trimming'; }

kit_ensure_cmd() { # <command> <debian-package> [auto-yes 0|1]
  have "$1" && return 0
  echo "'$1' is not installed (Debian package: $2)."
  local ans=n
  if [[ "${3:-0}" == 1 ]]; then ans=y; else read -rp "Install $2 now with apt (needs internet)? [y/N] " ans || true; fi
  [[ "$ans" == [yY]* ]] || return 1
  if ! apt-get install -y "$2" >/dev/null 2>&1; then
    if ! apt-get update >/dev/null 2>&1; then
      kit_error "apt-get update failed while installing $2" "no internet, or the enterprise repository is enabled without a subscription (401). Enable the pve-no-subscription repo or install $2 offline"
      return 1
    fi
    apt-get install -y "$2" >/dev/null 2>&1 || { kit_error "could not install $2" "run 'apt-get install $2' by hand to see the error"; return 1; }
  fi
  have "$1"
}

kit_fio_hint() { # <fio stderr file> -> prints a hint for common fio failures
  local e; e=$(tr '\n' ' ' < "$1" 2>/dev/null)
  case "$e" in
    *"No space left"*)             echo "the pool/device ran out of space - use a smaller -s size" ;;
    *"Permission denied"*)         echo "run as root" ;;
    *"Device or resource busy"*)   echo "the device is in use (mounted, in a pool, or attached to a VM)" ;;
    *"Read-only file system"*|*readonly*) echo "target is read-only" ;;
    *"No such file"*)              echo "device path disappeared - check it with lsblk" ;;
    *"engine libaio not loadable"*) echo "fio was built without libaio - reinstall fio from Debian" ;;
    *)                             echo "see the .err file in the raw/ folder" ;;
  esac
}
