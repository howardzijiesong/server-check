#!/usr/bin/env bash
# =============================================================================
# pve-bench.sh - fio benchmark of the storage layers underneath the Windows VM
# -----------------------------------------------------------------------------
# POOL MODE (default, non-destructive):
#   Layer 1: raw NVMe pool members, READ-ONLY (safe on a live pool)
#   Layer 2: temporary test zvols on the VM's pool, one per volblocksize:
#            4K sync vs async writes, reads, mixed load, sync=disabled cost.
#   Test zvols are named <parent>/zz-bench-<vbs>, created one at a time and
#   destroyed after use (and on exit / Ctrl+C). Existing data is never written.
#
# DEVICE MODE (-D, DESTRUCTIVE - for a spare/blank test SSD only):
#   Same tests on the RAW device, then on a zvol in a temporary pool built on
#   that same device -> an apples-to-apples "ZFS vs no ZFS" comparison on
#   identical media. The device is WIPED. Requires typing a confirmation.
#
# Run it while users are OFF the system.
#
# Usage:
#   ./pve-bench.sh -m <vmid> -k <disk>     pool mode, derived from the VM data disk (e.g. -m 100 -k scsi1)
#   ./pve-bench.sh -d <parent_dataset>     pool mode on a dataset (e.g. -d FastPool)
#   ./pve-bench.sh -D /dev/disk/by-id/ata-XYZ [-m <vmid> -k <disk>] [-K]   device mode
# Options:
#   -b "4k 16k 64k"  volblocksizes to compare (VM disk's current one is always added)
#   -r 30            seconds per test (default 30)
#   -s 4G            test size (default 4G)
#   -n "dev ..."     raw devices for the read-only test (default: the pool's members)
#   -q               quick: 15 s tests, current volblocksize only, no sequential tests
#   -K               device mode: keep the temporary pool + a 'winvol' zvol to attach to the VM
#   -y               don't ask "Proceed?" (the device-mode wipe confirmation is always asked)
# Output: <script dir>/results/pve-bench-<host>-<timestamp>/ (log .txt, .jsonl, results.csv, raw/)
# =============================================================================
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@" #
if grep -q $'\r' "$0" 2>/dev/null; then echo "ERROR: this file has Windows (CRLF) line endings. Fix: sed -i 's/\r\$//' $(dirname "$0")/*.sh"; exit 2; fi #
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=kit-common.sh
. "$SCRIPT_DIR/kit-common.sh" 2>/dev/null || { echo "ERROR: $SCRIPT_DIR/kit-common.sh is missing - copy the whole proxmox/ folder."; exit 2; }
usage() { sed -n '2,33p' "$0"; exit 1; }

VMID=""; DISKKEY=""; PARENT=""; VBS_LIST="4k 16k 64k"; RUNTIME=30; SIZE="4G"; RAWDEVS=""; QUICK=0; YES=0; TESTDEV=""; KEEP=0
ARGS="$*"
while getopts "m:k:d:b:r:s:n:D:qKyh" o; do
  case $o in
    m) VMID=$OPTARG ;;    k) DISKKEY=$OPTARG ;; d) PARENT=$OPTARG ;;  b) VBS_LIST=$OPTARG ;;
    r) RUNTIME=$OPTARG ;; s) SIZE=$OPTARG ;;    n) RAWDEVS=$OPTARG ;; D) TESTDEV=$OPTARG ;;
    q) QUICK=1 ;;         K) KEEP=1 ;;          y) YES=1 ;;           *) usage ;;
  esac
done

kit_require_root
kit_require_pve
[[ "$RUNTIME" =~ ^[0-9]+$ ]] || kit_die "-r must be a whole number of seconds" "example: -r 30"
size_bytes=$(numfmt --from=iec "${SIZE^^}" 2>/dev/null) || kit_die "bad size '$SIZE'" "use e.g. -s 4G"

# ------------------------------------------------------------ VM disk context
CUR_VBS=""; CUR_SYNC=""; CUR_COMP=""; VMDS=""
if [[ -n "$VMID" ]]; then
  kit_require_vm "$VMID"
  [[ -n "$DISKKEY" ]] || kit_die "-m needs -k <disk key>" "see the disk keys (scsi0, scsi1, ...) with: qm config $VMID"
  line=$(qm config "$VMID" | sed -n "s/^$DISKKEY: //p")
  [[ -n "$line" ]] || kit_die "disk '$DISKKEY' not found in VM $VMID" "valid keys: $(qm config "$VMID" | grep -oE '^(scsi|virtio|sata|ide)[0-9]+' | xargs)"
  volid=${line%%,*}
  path=$(pvesm path "$volid" 2>/dev/null) || kit_die "cannot resolve $volid" "is the storage online? pvesm status"
  if [[ "$path" == /dev/zvol/* ]]; then
    VMDS=${path#/dev/zvol/}
    CUR_VBS=$(zfs get -H -o value volblocksize "$VMDS"); CUR_SYNC=$(zfs get -H -o value sync "$VMDS"); CUR_COMP=$(zfs get -H -o value compression "$VMDS")
    [[ -z "$PARENT" && -z "$TESTDEV" ]] && PARENT=${VMDS%/*}
  elif [[ -z "$TESTDEV" ]]; then
    kit_die "$DISKKEY is not a ZFS zvol ($path)" "pool mode needs a ZFS-backed disk; for a directly attached disk use Server-DiskBench.ps1 inside Windows"
  fi
fi

lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
if (( QUICK )); then RUNTIME=15; VBS_LIST="${CUR_VBS:-16k}"; fi
[[ -n "$CUR_VBS" ]] && VBS_LIST="$CUR_VBS $VBS_LIST"
VBS_LIST=$(for v in $VBS_LIST; do lc "$v"; done | awk '!seen[$0]++' | xargs)
PRIMARY=$(awk '{print $1}' <<<"$VBS_LIST")

# ------------------------------------------------------------ mode checks
MODE=pool
if [[ -n "$TESTDEV" ]]; then
  MODE=device
  DEV=$(readlink -f "$TESTDEV")
  [[ -b "$DEV" ]] || kit_die "'$TESTDEV' is not a block device" "use a whole-disk path from: ls -l /dev/disk/by-id/"
  [[ "$(lsblk -dno TYPE "$DEV")" == disk ]] || kit_die "$DEV is a partition, not a whole disk" "pass the whole disk, e.g. /dev/sdX, not /dev/sdX1"
  lsblk -nro MOUNTPOINT "$DEV" | grep -q . && kit_die "$DEV (or a partition on it) is mounted" "unmount it first; never use a disk that holds data you need"
  zpool status -LP 2>/dev/null | grep -qE "[[:space:]]${DEV}(p?[0-9]+)?[[:space:]]" && kit_die "$DEV is a member of an existing ZFS pool" "this is not a spare disk - pick the blank test SSD"
  have pvs && pvs --noheadings -o pv_name 2>/dev/null | grep -q "$DEV" && kit_die "$DEV is an LVM physical volume" "not a spare disk"
  for l in /dev/disk/by-id/*; do
    [[ "$(readlink -f "$l")" == "$DEV" ]] || continue
    used=$(grep -l "$(basename "$l")" /etc/pve/qemu-server/*.conf 2>/dev/null | xargs -r -n1 basename | xargs)
    [[ -n "$used" ]] && kit_die "$DEV is attached to a VM ($used)" "detach it first (qm set <vmid> --delete scsiN) if it really is the blank test disk"
  done
  [[ "$(findmnt -no SOURCE / 2>/dev/null)" == "$DEV"* ]] && kit_die "$DEV holds the root filesystem" "wrong disk"
  zpool list -H zzbench >/dev/null 2>&1 && kit_die "a pool named 'zzbench' already exists" "left over from an earlier run? check it, then: zpool destroy zzbench"
  kit_ensure_cmd wipefs util-linux "$YES" || kit_die "wipefs is required"
else
  [[ -n "$PARENT" ]] || usage
  zfs list -H -o name "$PARENT" >/dev/null 2>&1 || kit_die "dataset '$PARENT' not found" "names are case-sensitive; list with: zfs list -o name"
  POOL=${PARENT%%/*}
  [[ -z "$RAWDEVS" ]] && RAWDEVS=$(zpool list -v -H -P "$POOL" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}' | xargs)
  avail=$(zfs get -Hp -o value available "$PARENT")
  (( avail > size_bytes * 13 / 10 )) || kit_die "not enough free space in $PARENT (need ~$(numfmt --to=iec $((size_bytes * 13 / 10))))" "use a smaller -s, e.g. -s 2G"
fi

kit_ensure_cmd fio fio "$YES" || kit_die "fio is required" "install it with: apt install fio"
perl -MJSON::PP -e1 2>/dev/null || kit_die "perl JSON::PP is missing" "apt install perl"

nvbs=$(wc -w <<<"$VBS_LIST"); nraw=$(wc -w <<<"$RAWDEVS")
if [[ $MODE == device ]]; then est=$(( 10 * (RUNTIME + 4) / 60 + 2 )); else est=$(( (nraw + nvbs * 4 + (QUICK ? 1 : 4)) * (RUNTIME + 4) / 60 + nvbs )); fi
echo
echo "pve-bench plan ($MODE mode)"
if [[ $MODE == device ]]; then
  echo "  TEST DEVICE (WILL BE WIPED): $DEV  [$(lsblk -dno MODEL,SERIAL,SIZE,TRAN "$DEV" | xargs)]"
  echo "  current signatures on it:"; wipefs -n "$DEV" 2>/dev/null | sed 's/^/    /'; lsblk "$DEV" | sed 's/^/    /'
  echo "  volblocksize for the zvol test: $PRIMARY   keep pool afterwards: $([[ $KEEP == 1 ]] && echo yes || echo no)"
else
  echo "  pool / parent dataset : $POOL / $PARENT"
  echo "  VM disk               : ${VMDS:-n/a} (volblocksize ${CUR_VBS:-?}, sync ${CUR_SYNC:-?}, compression ${CUR_COMP:-?})"
  echo "  volblocksizes         : $VBS_LIST (primary: $PRIMARY)"
  echo "  raw devices (read-only): ${RAWDEVS:-none found}"
fi
echo "  size $SIZE, $RUNTIME s per test, estimated ~${est} min"
echo
if [[ $MODE == device ]]; then
  read -rp "Type WIPE $(basename "$DEV") to destroy everything on this device and continue: " a
  [[ "$a" == "WIPE $(basename "$DEV")" ]] || { echo "Confirmation not given - nothing was changed."; exit 0; }
elif (( ! YES )); then
  read -rp "Proceed? [y/N] " a; [[ "$a" == [yY]* ]] || exit 0
fi

# ------------------------------------------------------------ logging + cleanup
OUT="$SCRIPT_DIR/results/pve-bench-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
RAW="$OUT/raw"
kit_init pve-bench "$OUT" "$ARGS"
mkdir -p "$RAW"
CSV="$OUT/results.csv"
echo "label,r_iops,r_MBps,r_lat_avg_us,r_lat_p99_us,w_iops,w_MBps,w_lat_avg_us,w_lat_p99_us" > "$CSV"
KIT_CAT="pvebench/$MODE"
kit_fact mode "$MODE"; kit_fact primary_volblocksize "$PRIMARY"; kit_fact vm_disk "${VMDS:-n/a}"
kit_fact cpu_model "$(lscpu | sed -n 's/^Model name:[[:space:]]*//p')"
[[ $MODE == device ]] && kit_fact test_device "$(lsblk -dno MODEL,SIZE,TRAN "$DEV" | xargs)"

declare -a CREATED=()
POOL_CREATED=0
destroy_ds() {
  local ds=$1
  [[ -n "$ds" && "$ds" == "$PARENT"/zz-bench-* ]] || return 0
  for _ in 1 2 3 4 5; do
    # -r only removes snapshots of this test zvol (e.g. taken by sanoid mid-run)
    zfs destroy -r "$ds" 2>/dev/null && { echo "  removed test zvol $ds"; return 0; }
    sleep 2
  done
  kit_error "could not destroy $ds" "remove it manually: zfs destroy -r $ds"
}
kit_cleanup() {
  local ds
  for ds in "${CREATED[@]}"; do destroy_ds "$ds"; done
  CREATED=()
  if (( POOL_CREATED && ! KEEP )); then
    zpool destroy zzbench 2>/dev/null && echo "  removed temporary pool zzbench"
    wipefs -aq "$DEV" 2>/dev/null
    POOL_CREATED=0
  fi
}
trap 'echo; echo "Interrupted - cleaning up."; exit 130' INT TERM

echo "pve-bench $KIT_VERSION  $(date -Is)  host=$(hostname)  $(fio --version)"
if [[ $MODE == pool ]] && kit_pool_busy "$POOL"; then
  kit_error "scrub/resilver/trim in progress on $POOL - results will be pessimistic" "wait for it (zpool status) or re-run later"
fi

# ------------------------------------------------------------ fio helpers
COMMON=(--ioengine=libaio --direct=1 --time_based --runtime="$RUNTIME" --ramp_time=3
        --group_reporting --randrepeat=0 --norandommap --refill_buffers --lat_percentiles=1)

parse() {
  perl -MJSON::PP -e '
    local $/; my $t = <STDIN>; $t =~ s/^[^{]*//s;
    my $j = eval { decode_json($t) } or do { print "0 0 0 0 0 0 0 0\n"; exit };
    my $job = $j->{jobs}[0]; my @o;
    for my $d ("read", "write") {
      my $x = $job->{$d} || {};
      my $lat = ($x->{lat_ns} && $x->{lat_ns}{mean}) ? $x->{lat_ns} : ($x->{clat_ns} || {});
      my $pct = $lat->{percentile} || ($x->{clat_ns} || {})->{percentile} || {};
      push @o, sprintf("%.0f", $x->{iops} || 0), sprintf("%.1f", ($x->{bw_bytes} || 0) / 1048576),
               sprintf("%.1f", ($lat->{mean} || 0) / 1000), sprintf("%.1f", ($pct->{"99.000000"} || 0) / 1000);
    }
    print join(" ", @o), "\n";' < "$1"
}
side() { [[ "$1" == "0" ]] && return; printf '%s %8s IOPS %8s MB/s  avg %8s us  p99 %8s us' "$5" "$1" "$2" "$3" "$4"; }

run_test() { # label target [fio args...]
  local label=$1 target=$2; shift 2
  local js="$RAW/${label}.json" err="$RAW/${label}.err"
  printf '  %-46s ' "$label"
  if ! fio --name="$label" --filename="$target" "${COMMON[@]}" "$@" --output-format=json --output="$js" >/dev/null 2>"$err"; then
    echo "FAILED"
    kit_error "fio test $label failed" "$(kit_fio_hint "$err")"
    return
  fi
  local ri rb rl rp wi wb wl wp
  read -r ri rb rl rp wi wb wl wp < <(parse "$js")
  echo "$(side "$ri" "$rb" "$rl" "$rp" R)$(side "$wi" "$wb" "$wl" "$wp" '  W')"
  echo "$label,$ri,$rb,$rl,$rp,$wi,$wb,$wl,$wp" >> "$CSV"
  if [[ "$ri" != "0" ]]; then kit_metric "$label.r_iops" "$ri"; kit_metric "$label.r_lat_avg_us" "$rl" us; kit_metric "$label.r_lat_p99_us" "$rp" us; fi
  if [[ "$wi" != "0" ]]; then kit_metric "$label.w_iops" "$wi"; kit_metric "$label.w_lat_avg_us" "$wl" us; kit_metric "$label.w_lat_p99_us" "$wp" us; fi
}

prefill() { # target
  printf '  %-46s ' "prefill ($SIZE, incompressible)"
  if fio --name=prefill --filename="$1" --ioengine=libaio --direct=1 --rw=write --bs=1M --iodepth=16 \
         --size="$SIZE" --refill_buffers >/dev/null 2>"$RAW/prefill.err"; then echo "done"
  else echo "FAILED"; kit_error "prefill of $1 failed" "$(kit_fio_hint "$RAW/prefill.err")"; fi
}

core_tests() { # prefix target [extra: 1 = also SYNCOFF via dataset $3]
  local pfx=$1 tgt=$2
  run_test "$pfx-randread-4k-qd1"        "$tgt" --size="$SIZE" --rw=randread  --bs=4k --iodepth=1 --numjobs=1
  run_test "$pfx-randwrite-4k-qd1-sync"  "$tgt" --size="$SIZE" --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --sync=1
  run_test "$pfx-randwrite-4k-qd1-async" "$tgt" --size="$SIZE" --rw=randwrite --bs=4k --iodepth=1 --numjobs=1
  run_test "$pfx-randrw70-4k-qd8x4"      "$tgt" --size="$SIZE" --rw=randrw --rwmixread=70 --bs=4k --iodepth=8 --numjobs=4
}

wait_dev() { for _ in $(seq 1 50); do [[ -b "$1" ]] && return 0; sleep 0.2; done; return 1; }

make_zvol() { # dataset vbs [primarycache] -> sets ZDEV; no subshell so CREATED stays accurate
  local ds=$1 vbs=$2 pc=${3:-metadata}
  local -a opts=(-o volblocksize="$vbs" -o primarycache="$pc")
  [[ -n "$CUR_COMP" ]] && opts+=(-o compression="$CUR_COMP")
  [[ -n "$CUR_SYNC" ]] && opts+=(-o sync="$CUR_SYNC")
  if zfs list -H -o name "$ds" >/dev/null 2>&1; then
    kit_error "$ds already exists" "left over from an earlier run? inspect it, then: zfs destroy -r $ds"; return 1
  fi
  zfs create -s -V "${4:-$SIZE}" "${opts[@]}" "$ds" 2>&1 | grep -v 'less than 16K' || true
  zfs list -H -o name "$ds" >/dev/null 2>&1 || { kit_error "could not create $ds" "check free space: zfs list"; return 1; }
  [[ "$ds" == "$PARENT"/zz-bench-* ]] && CREATED+=("$ds")
  udevadm settle 2>/dev/null || true
  wait_dev "/dev/zvol/$ds" || { kit_error "/dev/zvol/$ds did not appear" "udev slow? re-run"; return 1; }
  ZDEV=/dev/zvol/$ds
}

# =============================================================== DEVICE MODE
if [[ $MODE == device ]]; then
  KIT_CAT="pvebench/device"
  echo; echo "== Device layer 1: RAW $DEV (no filesystem, no ZFS) =="
  wipefs -aq "$DEV" || kit_die "wipefs failed on $DEV" "is it in use?"
  prefill "$DEV"
  core_tests "dev-raw" "$DEV"

  echo; echo "== Device layer 2: ZFS zvol on the same device (pool zzbench, volblocksize $PRIMARY) =="
  if zpool create -f -o ashift=12 -O compression=lz4 -O atime=off -m none zzbench "$DEV"; then
    POOL_CREATED=1
    kit_fact test_pool "zzbench ashift=12 on $DEV"
    if make_zvol zzbench/bench "$PRIMARY" metadata; then
      prefill "$ZDEV"; zpool sync zzbench 2>/dev/null
      core_tests "dev-zvol-$PRIMARY" "$ZDEV"
      zfs set sync=disabled zzbench/bench
      run_test "dev-zvol-$PRIMARY-randwrite-4k-qd1-SYNCOFF" "$ZDEV" --size="$SIZE" --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --sync=1
      zfs destroy zzbench/bench
    fi
    if (( KEEP )); then
      pool_free=$(zfs get -Hp -o value available zzbench)
      winsize=$(( pool_free * 7 / 10 / 1073741824 ))G
      if make_zvol zzbench/winvol "$PRIMARY" all "$winsize"; then
        zfs set sync=standard zzbench/winvol
        echo
        echo "Kept pool zzbench with zvol zzbench/winvol ($winsize) for a Windows-side test:"
        echo "  qm set ${VMID:-<vmid>} --scsi9 /dev/zvol/zzbench/winvol,backup=0,iothread=1,discard=on,ssd=1"
        echo "  (Windows: Disk Management > initialize > NTFS 4K; run Server-DiskBench/SmallFile-Test with -Label ssd-zfs)"
        echo "Afterwards:  qm set ${VMID:-<vmid>} --delete scsi9 ; zpool destroy zzbench ; wipefs -a $DEV"
        echo "Native NTFS on the same SSD (after destroying the pool):"
        echo "  qm set ${VMID:-<vmid>} --scsi9 /dev/disk/by-id/<this ssd id>,backup=0,iothread=1,discard=on,ssd=1   (-Label ssd-native)"
      fi
    fi
  else
    kit_error "zpool create on $DEV failed" "the device may still be in use; check lsblk / wipefs -n"
  fi
  p=$PRIMARY
fi

# =============================================================== POOL MODE
if [[ $MODE == pool ]]; then
  # shellcheck disable=SC2034  # used by kit-common.sh functions
  KIT_CAT="pvebench/pool"
  echo; echo "== Layer 1: raw NVMe, 4K random read QD1, READ-ONLY =="
  echo "   (upper bound: never-written flash blocks read faster than real data)"
  for rdev in $RAWDEVS; do
    short=$(basename "$(readlink -f "$rdev")")
    run_test "raw-${short}-randread-4k-qd1" "$rdev" --readonly --rw=randread --bs=4k --iodepth=1 --numjobs=1
  done
  for vbs in $VBS_LIST; do
    echo; echo "== Layer 2: test zvol, volblocksize=$vbs (primarycache=metadata: reads hit flash, not ARC) =="
    ds="$PARENT/zz-bench-$vbs"
    make_zvol "$ds" "$vbs" metadata || continue
    prefill "$ZDEV"; zpool sync "$POOL" 2>/dev/null || sync
    core_tests "zvol-$vbs" "$ZDEV"
    if [[ "$vbs" == "$PRIMARY" ]]; then
      if (( ! QUICK )); then
        run_test "zvol-$vbs-randwrite-64k-qd1-sync" "$ZDEV" --size="$SIZE" --rw=randwrite --bs=64k --iodepth=1 --numjobs=1 --sync=1
        run_test "zvol-$vbs-seqread-1m-qd8"         "$ZDEV" --size="$SIZE" --rw=read  --bs=1M --iodepth=8 --numjobs=1
        run_test "zvol-$vbs-seqwrite-1m-qd8"        "$ZDEV" --size="$SIZE" --rw=write --bs=1M --iodepth=8 --numjobs=1
      fi
      zfs set sync=disabled "$ds"
      run_test "zvol-$vbs-randwrite-4k-qd1-SYNCOFF" "$ZDEV" --size="$SIZE" --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --sync=1
      zfs set sync="${CUR_SYNC:-standard}" "$ds"
    fi
    destroy_ds "$ds"
    tmp=(); for x in "${CREATED[@]}"; do [[ "$x" != "$ds" ]] && tmp+=("$x"); done; CREATED=("${tmp[@]}")
  done
  p=$PRIMARY
fi

# =============================================================== SUMMARY
getv()  { awk -F, -v l="$1" -v c="$2" '$1==l {print $c}' "$CSV"; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (a > 0 && b > 0) printf "%.1f", a / b; else print "n/a" }'; }
echo; echo "================ SUMMARY ================"
column -s, -t < "$CSV"
echo
if [[ $MODE == device ]]; then
  rs=$(getv dev-raw-randwrite-4k-qd1-sync 8); zs=$(getv "dev-zvol-$p-randwrite-4k-qd1-sync" 8)
  rr=$(getv dev-raw-randread-4k-qd1 4);       zr=$(getv "dev-zvol-$p-randread-4k-qd1" 4)
  echo "Same device, no ZFS vs ZFS zvol:"
  echo "  4K sync write : raw ${rs:-?} us  vs  zvol ${zs:-?} us  -> ZFS costs $(ratio "${zs:-0}" "${rs:-0}")x"
  echo "  4K read       : raw ${rr:-?} us  vs  zvol ${zr:-?} us  -> ZFS costs $(ratio "${zr:-0}" "${rr:-0}")x"
  kit_metric zfs_overhead_sync_write_x "$(ratio "${zs:-0}" "${rs:-0}")" x
  kit_metric zfs_overhead_read_x "$(ratio "${zr:-0}" "${rr:-0}")" x
  echo "  Note: consumer SSDs without power-loss protection are slow at flushes, which exaggerates"
  echo "  the ZFS sync cost compared with the enterprise CD6 drives (which have PLP)."
else
  s_lat=$(getv "zvol-$p-randwrite-4k-qd1-sync" 8); a_lat=$(getv "zvol-$p-randwrite-4k-qd1-async" 8)
  off_lat=$(getv "zvol-$p-randwrite-4k-qd1-SYNCOFF" 8); zr_lat=$(getv "zvol-$p-randread-4k-qd1" 4)
  echo "Primary volblocksize $p:"
  echo "  4K sync write latency : ${s_lat:-?} us   (async: ${a_lat:-?} us -> sync costs $(ratio "${s_lat:-0}" "${a_lat:-0}")x)"
  echo "  with sync=disabled    : ${off_lat:-?} us   ($(ratio "${s_lat:-0}" "${off_lat:-0}")x faster than sync=standard)"
  echo "  4K random read (flash): ${zr_lat:-?} us"
  kit_metric sync_vs_async_x "$(ratio "${s_lat:-0}" "${a_lat:-0}")" x
  kit_metric syncoff_speedup_x "$(ratio "${s_lat:-0}" "${off_lat:-0}")" x
  for rdev in $RAWDEVS; do
    short=$(basename "$(readlink -f "$rdev")"); rl=$(getv "raw-${short}-randread-4k-qd1" 4)
    [[ -n "$rl" ]] && echo "  raw $short 4K read    : ${rl} us  (zvol read is $(ratio "${zr_lat:-0}" "${rl:-0}")x of raw)"
  done
  best=$(awk -F, '$1 ~ /^zvol-.*-randwrite-4k-qd1-sync$/ {print $6, $1}' "$CSV" | sort -rn | head -1)
  if [[ -n "$best" ]]; then echo "  best volblocksize for 4K sync writes: ${best#* } (${best%% *} IOPS)"; kit_fact best_vbs_sync4k "${best#* }"; fi
fi
cat <<'TXT'

How to use these numbers
  * Host "zvol-<vbs>-randwrite-4k-qd1-sync" vs Server-DiskBench.ps1 "4K write-through" inside the VM:
    VM latency minus host latency = cost of the virtualization layer (controller, iothread, CPU/VBS).
  * sync vs SYNCOFF shows what ZFS sync semantics cost. sync=disabled can lose the last few
    seconds of acknowledged writes on a crash/power cut - only with a proper UPS + auto-shutdown.
  * Small-file SMB time over a VPN is dominated by network round trips, not by these numbers.
TXT
echo; echo "Results folder: $OUT"
