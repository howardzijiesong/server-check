#!/usr/bin/env bash
# =============================================================================
# pve-monitor.sh - record host-side storage/CPU behaviour while users
#                  reproduce the slowness (open a CaseWare file, a TaxCycle
#                  return, etc.). Read-only; run alongside Perf-Monitor.ps1.
# -----------------------------------------------------------------------------
# Usage:   ./pve-monitor.sh -p <pool> [-m <vmid>] [-t <seconds>] [-i <interval>]
#            -t 0  = run until you press Enter (default 600 s)
#            -i    = sample interval in seconds (default 2)
# Example: ./pve-monitor.sh -p rpool -m 100 -t 0
# Output:  <script dir>/results/pve-monitor-<host>-<timestamp>/
# =============================================================================
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@" #
if grep -q $'\r' "$0" 2>/dev/null; then echo "ERROR: this file has Windows (CRLF) line endings. Fix: sed -i 's/\r\$//' $(dirname "$0")/*.sh"; exit 2; fi #
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=kit-common.sh
. "$SCRIPT_DIR/kit-common.sh" 2>/dev/null || { echo "ERROR: $SCRIPT_DIR/kit-common.sh is missing - copy the whole proxmox/ folder."; exit 2; }
usage() { sed -n '2,13p' "$0"; exit 1; }

POOL=""; VMID=""; DUR=600; INT=2; ARGS="$*"
while getopts "p:m:t:i:h" o; do
  case $o in p) POOL=$OPTARG ;; m) VMID=$OPTARG ;; t) DUR=$OPTARG ;; i) INT=$OPTARG ;; *) usage ;; esac
done
[[ -n "$POOL" ]] || usage
[[ "$DUR" =~ ^[0-9]+$ && "$INT" =~ ^[0-9]+$ && "$INT" -gt 0 ]] || kit_die "-t and -i must be whole numbers (-i > 0)" "example: -t 0 -i 2"
kit_require_root
kit_require_pool "$POOL"
[[ -n "$VMID" ]] && kit_require_vm "$VMID"
zpool iostat -l "$POOL" 1 1 >/dev/null 2>&1 || kit_die "'zpool iostat -l' is not supported by this ZFS version" "update Proxmox/ZFS; OpenZFS 0.8+ is required"

OUT="$SCRIPT_DIR/results/pve-monitor-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
kit_init pve-monitor "$OUT" "$ARGS"
# shellcheck disable=SC2034  # used by kit-common.sh functions
KIT_CAT="pvemonitor"
if [[ -n "$VMID" ]] && ! qm status "$VMID" 2>/dev/null | grep -q running; then
  kit_error "VM $VMID is not running - per-VM capture (QEMU threads, NIC) will be skipped" "start the VM (qm start $VMID) before recording"
fi
if kit_pool_busy "$POOL"; then kit_error "scrub/resilver/trim running on $POOL - latency will look worse than normal" "note it in your results or re-run later"; fi

declare -a PIDS=()
bg() { local name=$1; shift; "$@" > "$OUT/$name.txt" 2>&1 & PIDS+=($!); }
stop_all() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  PIDS=()
}
STOP=0
kit_cleanup() { stop_all; }
trap 'STOP=1' INT TERM

echo "Recording to $OUT (interval ${INT}s)"
bg zpool-iostat-latency zpool iostat -T d -vly "$POOL" "$INT"
bg zpool-iostat-queues  zpool iostat -T d -vqy "$POOL" "$INT"
bg vmstat vmstat -n -t "$INT"
have arcstat && bg arcstat arcstat "$INT"
psi_loop() { while :; do printf '%s %s\n' "$(date +%T)" "$(tr '\n' ' ' < /proc/pressure/io)"; sleep "$INT"; done; }
nic_loop() { # tap interface: bytes to/from the VM per interval
  local t=$1 rx0 tx0 rx tx
  rx0=$(cat "/sys/class/net/$t/statistics/rx_bytes"); tx0=$(cat "/sys/class/net/$t/statistics/tx_bytes")
  while sleep "$INT"; do
    rx=$(cat "/sys/class/net/$t/statistics/rx_bytes"); tx=$(cat "/sys/class/net/$t/statistics/tx_bytes")
    awk -v ts="$(date +%T)" -v rx=$((rx - rx0)) -v tx=$((tx - tx0)) -v i="$INT" \
      'BEGIN { printf "%s  to-VM %8.2f MB/s   from-VM %8.2f MB/s\n", ts, tx / i / 1048576, rx / i / 1048576 }'
    rx0=$rx; tx0=$tx
  done
}
[[ -r /proc/pressure/io ]] && bg psi-io psi_loop

if [[ -n "$VMID" ]]; then
  pidfile=/var/run/qemu-server/$VMID.pid
  if [[ -r $pidfile ]]; then
    qpid=$(cat "$pidfile")
    bg qemu-threads top -b -H -d "$INT" -p "$qpid"
    tap="tap${VMID}i0"
    [[ -d /sys/class/net/$tap ]] && bg vm-nic nic_loop "$tap"
  else
    echo "VM $VMID does not appear to be running (no $pidfile) - skipping per-VM capture."
  fi
fi

echo
echo ">>> Now have a user reproduce the slowness (open the CaseWare engagement / TaxCycle return)."
if [[ "$DUR" == "0" ]]; then
  read -rp ">>> Press Enter to stop recording... " _ || true
else
  for (( left=DUR; left>0; left-=5 )); do
    (( STOP )) && break
    printf '\r>>> %4d s left (Ctrl+C stops early; the summary is still written) ' "$left"
    sleep 5
  done; echo
fi
stop_all

# ------------------------------------------------------------ summary
S="$OUT/summary.txt"
{
  echo "pve-monitor summary  pool=$POOL vm=${VMID:-n/a}  $(date -Is)"
  echo
  echo "ZFS pool-level latency (from zpool iostat -l, one line per ${INT}s sample):"
  awk -v pool="$POOL" '
    function us(v,   n, u) { if (v == "-" || v == "") return -1; n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
      if (u == "ns") return n / 1000; if (u == "us") return n; if (u == "ms") return n * 1000; if (u == "s") return n * 1000000; return n }
    function ops(v,   n, u) { n = v + 0; u = v; sub(/^[0-9.]+/, "", u); if (u == "K") return n * 1000; if (u == "M") return n * 1000000; return n }
    $1 == pool && NF >= 11 {
      n++; ro += ops($4); wo += ops($5)
      split("8 9 10 11", idx, " ")
      for (i = 1; i <= 4; i++) { c = idx[i]; x = us($c); if (x >= 0) { sum[c] += x; cnt[c]++; if (x > mx[c]) mx[c] = x } }
      w = us($9); if (w > 10000) spikes++
    }
    END {
      if (!n) { print "  no samples"; exit }
      printf "  samples: %d   avg read ops/s: %.0f   avg write ops/s: %.0f\n", n, ro / n, wo / n
      split("8 9 10 11", idx, " "); split("total_wait-read total_wait-write disk_wait-read disk_wait-write", nm, " ")
      for (i = 1; i <= 4; i++) { c = idx[i]; if (cnt[c]) printf "  %-17s avg %9.0f us   max %10.0f us\n", nm[i], sum[c] / cnt[c], mx[c] }
      printf "  samples with write total_wait > 10 ms: %d\n", spikes + 0
      for (i = 1; i <= 4; i++) { c = idx[i]; if (cnt[c]) printf "@M %s_avg_us %.0f us\n@M %s_max_us %.0f us\n", nm[i], sum[c] / cnt[c], nm[i], mx[c] }
      printf "@M write_wait_spikes_over_10ms %d count\n", spikes + 0
    }' "$OUT/zpool-iostat-latency.txt"
  echo "  (total_wait = time in ZFS incl. queues; disk_wait = time at the NVMe. Healthy NVMe: tens to a few hundred us.)"
  echo
  echo "vmstat (host CPU):"
  awk '
    /^ *r +b/ { for (i = 1; i <= NF; i++) col[$i] = i; next }
    col["wa"] && $1 ~ /^[0-9]+$/ {
      n++; wa = $(col["wa"]); st = $(col["st"]); id = $(col["id"])
      swa += wa; if (wa > mwa) mwa = wa; if (st > mst) mst = st; if (100 - id > mbusy) mbusy = 100 - id
      si += $(col["si"]); so += $(col["so"])
    }
    END { if (n) { printf "  samples %d  iowait avg %.1f%% max %d%%  max CPU busy %d%%  max steal %d%%  swap-in total %d  swap-out total %d\n", n, swa / n, mwa, mbusy, mst, si, so
                   printf "@M host_iowait_max_pct %d pct\n@M host_cpu_busy_max_pct %d pct\n@M host_swap_in_total %d pages\n", mwa, mbusy, si } }' "$OUT/vmstat.txt"
  echo
  echo "I/O pressure (PSI 'some' avg10, % of time at least one task waited on I/O):"
  grep -oE 'some avg10=[0-9.]+' "$OUT/psi-io.txt" 2>/dev/null | cut -d= -f2 | sort -n | awk '{a[NR] = $1} END { if (NR) { printf "  median %.2f%%   max %.2f%%\n", a[int((NR + 1) / 2)], a[NR]; printf "@M io_pressure_max_pct %.2f pct\n", a[NR] } }'
  if [[ -s "$OUT/qemu-threads.txt" ]]; then
    echo
    echo "Busiest QEMU threads for VM $VMID (max %CPU seen; ~100% on one thread = that thread is a bottleneck):"
    awk '$1 ~ /^[0-9]+$/ && NF >= 12 { name = $12; for (i = 13; i <= NF; i++) name = name " " $i; c = $9 + 0; if (c > m[name]) m[name] = c }
         END { for (k in m) printf "  %6.1f%%  %s\n", m[k], k }' "$OUT/qemu-threads.txt" | sort -rn | head -12
  fi
} | while IFS= read -r l; do
  if [[ "$l" == "@M "* ]]; then read -r _ k v u <<<"$l"; kit_metric "$k" "$v" "$u"; else printf '%s\n' "$l"; fi
done | tee "$S"
echo
echo "Raw logs: $OUT"
