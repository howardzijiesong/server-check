#!/usr/bin/env bash
# =============================================================================
# pve-audit.sh - READ-ONLY audit of a Proxmox VE host and one Windows VM
# -----------------------------------------------------------------------------
# Collects host / NVMe / ZFS / VM / backup-job configuration and flags the
# settings that are known to hurt small-file SMB workloads (CaseWare,
# TaxCycle) on a Windows file-server VM. Makes NO changes; safe any time.
#
# Usage:    ./pve-audit.sh <vmid> [output_dir]
# Example:  ./pve-audit.sh 100
# Output:   <script dir>/results/pve-audit-<host>-<timestamp>.txt (+ .jsonl for Analyze-Results.ps1)
# =============================================================================
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@" #
if grep -q $'\r' "$0" 2>/dev/null; then echo "ERROR: this file has Windows (CRLF) line endings. Fix: sed -i 's/\r\$//' $(dirname "$0")/*.sh"; exit 2; fi #
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=kit-common.sh
. "$SCRIPT_DIR/kit-common.sh" 2>/dev/null || { echo "ERROR: $SCRIPT_DIR/kit-common.sh is missing - copy the whole proxmox/ folder, not single scripts."; exit 2; }

VMID="${1:-}"
OUTDIR="${2:-$SCRIPT_DIR/results}"
if [[ -z "$VMID" || "$VMID" == "-h" || "$VMID" == "--help" ]]; then
  sed -n '2,13p' "$0"; exit 1
fi
kit_require_root
kit_require_pve
kit_require_vm "$VMID"
kit_init pve-audit "$OUTDIR" "$@"
REPORT=$KIT_LOG

declare -a FLAGS=()
warn()    { FLAGS+=("[WARN] $*"); kit_rec WARN "$KIT_CAT" "" "$*"; }
info()    { FLAGS+=("[INFO] $*"); kit_rec INFO "$KIT_CAT" "" "$*"; }
good()    { FLAGS+=("[ OK ] $*"); kit_rec OK "$KIT_CAT" "" "$*"; }
section() { kit_section "$@"; }
show()    { printf '\n$ %s\n' "$*"; "$@" 2>&1 || true; }

main() {
  echo "pve-audit.sh  host=$(hostname -f 2>/dev/null || hostname)  vm=$VMID  date=$(date -Is)"

  # ---------------------------------------------------------------- HOST
  section "HOST"
  show pveversion
  echo "Kernel: $(uname -r)"
  lscpu | grep -E '^(Model name|CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|NUMA node\(s\)|CPU max MHz)'
  show free -h
  echo; echo "Load average: $(cat /proc/loadavg)"
  if [[ -r /proc/pressure/io ]]; then echo "I/O pressure (PSI, % of time tasks stalled on I/O):"; sed 's/^/  /' /proc/pressure/io; fi

  HOST_THREADS=$(nproc)
  MEM_TOTAL_KB=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
  kit_fact cpu_model "$(lscpu | sed -n 's/^Model name:[[:space:]]*//p')"
  kit_fact host_threads "$HOST_THREADS"
  kit_fact host_mem_gib "$((MEM_TOTAL_KB / 1048576))"

  if compgen -G "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" >/dev/null; then
    gov=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | xargs)
    drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
    echo "CPU governor: $gov (driver: $drv)"
    kit_fact cpu_governor "$gov"
    [[ "$gov" == *performance* ]] || info "CPU governor is '$gov'. 'performance' removes frequency-ramp latency on bursty small I/O (costs some idle power). Try: apt install linux-cpupower && cpupower frequency-set -g performance"
  else
    echo "CPU governor: not exposed to the OS (BIOS-controlled). Check BIOS power profile = Performance / OS-controlled."
  fi

  if grep -q 'AuthenticAMD' /proc/cpuinfo; then
    [[ -r /sys/devices/system/cpu/amd_pstate/status ]] && echo "amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status)"
    echo "NUMA nodes: $(lscpu | sed -n 's/^NUMA node(s):[[:space:]]*//p')  (EPYC: BIOS NPS setting; also set Determinism=Performance and review Global C-state control)"
  fi
  swap_used_mb=$(free -m | awk '/^Swap:/ {print $3}')
  (( ${swap_used_mb:-0} > 512 )) && warn "Host is using ${swap_used_mb} MiB of swap: host RAM is overcommitted (VM RAM + ZFS ARC). Swapping stalls VMs."
  ksm=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo 0)
  (( ksm > 0 )) && info "KSM is merging memory pages ($ksm pages): a sign of memory pressure; small CPU overhead."

  # --------------------------------------------------------- KERNEL LOG
  section "KERNEL LOG: storage errors since boot"
  klog=$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'nvme.*(timeout|reset|error|abort)|blk_update_request|I/O error|critical medium|zio.*err' | tail -n 30)
  if [[ -n "$klog" ]]; then
    echo "$klog"
    warn "Storage errors/timeouts found in the kernel log (see KERNEL LOG section). These cause multi-second stalls inside the VM."
  else
    echo "none found"
  fi

  # --------------------------------------------------------------- IOMMU
  section "IOMMU (only needed for the NVMe-passthrough option)"
  ngroups=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  echo "IOMMU groups: $ngroups"
  grep -oE '(intel_iommu|amd_iommu|iommu)=[^ ]+' /proc/cmdline || echo "(no iommu options on kernel cmdline)"
  (( ngroups == 0 )) && info "IOMMU is not active. NVMe passthrough to the VM would first need VT-d / AMD-Vi enabled in BIOS."

  # ---------------------------------------------------------------- NVMe
  section "NVMe DEVICES"
  lsblk -d -o NAME,MODEL,SERIAL,SIZE,ROTA,LOG-SEC,PHY-SEC,TRAN
  have nvme && show nvme list
  found_nvme=0
  for ctrl in /sys/class/nvme/nvme*; do
    [[ -e "$ctrl" ]] || continue
    found_nvme=1
    name=$(basename "$ctrl")
    model=$(xargs < "$ctrl/model" 2>/dev/null)
    fw=$(xargs < "$ctrl/firmware_rev" 2>/dev/null)
    pci=$(basename "$(readlink -f "$ctrl/device")")
    grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group" 2>/dev/null)" 2>/dev/null)
    lnk=$(lspci -vv -s "$pci" 2>/dev/null)
    linkinfo() { grep -m1 "$1" <<<"$lnk" | grep -oE 'Speed [0-9.]+GT/s|Width x[0-9]+' | awk '{print $2}' | xargs; }
    cap=$(linkinfo 'LnkCap:'); sta=$(linkinfo 'LnkSta:')
    echo
    echo "--- /dev/$name  model='$model'  fw=$fw  pci=$pci  iommu_group=${grp:-n/a}"
    echo "    PCIe link: capable [${cap:-?}]  running [${sta:-?}]"
    kit_fact "nvme.$name.model" "$model"
    kit_fact "nvme.$name.link" "running ${sta:-?} / capable ${cap:-?}"
    if [[ -n "$cap" && -n "$sta" && "$cap" != "$sta" ]]; then
      warn "/dev/$name PCIe link runs at [$sta] but the drive supports [$cap]. Expected on a PCIe 3.0 platform; otherwise check slot/riser/backplane/BIOS."
    fi
    if have nvme; then
      sl=$(nvme smart-log "/dev/$name" 2>/dev/null)
      grep -iE '^(critical_warning|temperature|available_spare|percentage_used|media_errors|num_err_log_entries)[[:space:]]' <<<"$sl" | sed 's/^/    /'
      me=$(awk -F: '/^media_errors/ {gsub(/[ ,]/,"",$2); print $2}' <<<"$sl")
      cw=$(awk -F: '/^critical_warning/ {gsub(/[ ,]/,"",$2); print $2}' <<<"$sl")
      [[ -n "$me" && "$me" != "0" ]] && warn "/dev/$name reports media_errors=$me"
      [[ -n "$cw" && "$cw" != "0" && "$cw" != "0x0" ]] && warn "/dev/$name critical_warning=$cw"
      lbaf=$(nvme id-ns -H "/dev/${name}n1" 2>/dev/null | grep -i 'in use' | head -1 | xargs)
      [[ -n "$lbaf" ]] && echo "    LBA format: $lbaf"
    else
      echo "    (install nvme-cli for SMART data: apt install nvme-cli)"
    fi
  done
  kit_fact nvme_controllers_visible "$found_nvme"
  (( found_nvme )) || warn "No NVMe controllers are visible to the host. If the CD6 drives sit behind a RAID / tri-mode controller they show up as /dev/sdX; ZFS should see raw disks (HBA/IT mode), never controller RAID volumes."

  # ----------------------------------------------------------------- ZFS
  section "ZFS POOLS"
  show zfs version
  show zpool list -v
  show zpool status -v
  for pool in $(zpool list -H -o name); do
    echo; echo "--- pool: $pool"
    zpool get -o property,value ashift,autotrim,capacity,fragmentation,health "$pool"
    vdev_ashift=$(zdb -C "$pool" 2>/dev/null | awk '$1=="ashift:" {print $2}' | sort -u | xargs)
    echo "vdev ashift (zdb): ${vdev_ashift:-unavailable}"
    for a in $vdev_ashift; do
      (( a < 12 )) && warn "Pool $pool has a vdev with ashift=$a (512-byte alignment) on 4K flash: write amplification. Only fixable by recreating the pool with ashift=12."
    done
    cap=$(zpool get -Hp -o value capacity "$pool"); frag=$(zpool get -Hp -o value fragmentation "$pool")
    kit_fact "pool.$pool.capacity_pct" "$cap"; kit_fact "pool.$pool.fragmentation_pct" "$frag"; kit_fact "pool.$pool.ashift" "${vdev_ashift:-?}"
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= 80 )) && warn "Pool $pool is ${cap}% full. ZFS gets noticeably slower past ~80%."
    [[ "$frag" =~ ^[0-9]+$ ]] && (( frag >= 50 )) && info "Pool $pool free-space fragmentation is ${frag}%."
    zpool status "$pool" | grep -qE 'scrub in progress|resilver in progress|trimming' && warn "Pool $pool has a scrub/resilver/trim IN PROGRESS - benchmarks run now will be skewed."
    dd=$(zfs get -H -r -o name,value dedup "$pool" 2>/dev/null | awk '$2!="off" {print $1}' | xargs)
    [[ -n "$dd" ]] && warn "Deduplication is ON for: $dd - large RAM and latency cost."
    sd=$(zfs get -H -r -o name,value sync "$pool" 2>/dev/null | awk '$2=="disabled" {print $1}' | xargs)
    [[ -n "$sd" ]] && info "sync=disabled on: $sd - fast, but the last few seconds of acknowledged writes can be lost on a host crash or power cut."
    sa=$(zfs get -H -r -o name,value sync "$pool" 2>/dev/null | awk '$2=="always" {print $1}' | xargs)
    [[ -n "$sa" ]] && warn "sync=always on: $sa - every write waits for the ZFS intent log."
    show zfs get compression,atime,primarycache,logbias,recordsize "$pool"
  done
  [[ -f /etc/cron.d/zfsutils-linux ]] && { echo; echo "Scheduled scrub/trim (Debian default: trim 1st Sunday, scrub 2nd Sunday of the month):"; grep -v '^#' /etc/cron.d/zfsutils-linux | sed '/^$/d; s/^/  /'; }

  # ----------------------------------------------------------------- ARC
  section "ZFS ARC (host RAM read cache)"
  A=/proc/spl/kstat/zfs/arcstats
  if [[ -r $A ]]; then
    arcv() { awk -v k="$1" '$1==k {print $3}' "$A"; }
    size=$(arcv size); cmax=$(arcv c_max); hits=$(arcv hits); misses=$(arcv misses)
    ratio=$(( (hits + misses) > 0 ? hits * 100 / (hits + misses) : 0 ))
    printf 'ARC size: %d MiB   max: %d MiB (%d%% of RAM)   hit ratio since boot: %d%%\n' \
      $((size / 1048576)) $((cmax / 1048576)) $((cmax / 1024 * 100 / MEM_TOTAL_KB)) "$ratio"
    echo "zfs_arc_max module parameter: $(cat /sys/module/zfs/parameters/zfs_arc_max) (0 = built-in default)"
    kit_fact arc_max_mib "$((cmax / 1048576))"; kit_fact arc_hit_pct "$ratio"
    (( cmax < 4 * 1024 * 1024 * 1024 )) && info "ARC max is under 4 GiB. Fine if the VM has plenty of RAM for its own file cache; otherwise hot small files are re-read from flash."
  fi

  # ------------------------------------------------------------------ VM
  section "VM $VMID CONFIG"
  CONF=$(qm config "$VMID")
  echo "$CONF"
  show qm status "$VMID"

  cfg() { sed -n "s/^$1: //p" <<<"$CONF" | head -1; }
  cpu=$(cfg cpu); cores=$(cfg cores); sockets=$(cfg sockets); mem=$(cfg memory)
  balloon=$(cfg balloon); numa=$(cfg numa); scsihw=$(cfg scsihw); ostype=$(cfg ostype)
  agent=$(cfg agent); machine=$(cfg machine)
  cores=${cores:-1}; sockets=${sockets:-1}; mem=${mem:-512}
  nv=$(( cores * sockets ))
  echo
  echo "vCPUs: $nv (host threads: $HOST_THREADS)  RAM: ${mem} MiB  balloon: ${balloon:-default}  scsihw: ${scsihw:-lsi (default)}  machine: ${machine:-default}  ostype: ${ostype:-?}"

  # CPU type / VBS risk
  ctype=${cpu%%,*}; ctype=${ctype#cputype=}
  nested_host=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo "?")
  kit_fact vm_cpu "${cpu:-default (kvm64)}"; kit_fact host_nested_virt "$nested_host"
  kit_fact vm_vcpus "$nv"; kit_fact vm_mem_mib "$mem"; kit_fact vm_scsihw "${scsihw:-lsi (default)}"; kit_fact vm_balloon "${balloon:-default}"
  case "$ctype" in
    "")
      warn "CPU type not set: QEMU default (kvm64) hides AES-NI/AVX2 from Windows, so SMB signing/encryption runs in slow software crypto. Set CPU type to x86-64-v3 (or x86-64-v2-AES on older hosts)." ;;
    kvm64|qemu64|kvm32|qemu32)
      warn "CPU type '$ctype' hides AES-NI/AVX2 from Windows (slow SMB signing/encryption). Use x86-64-v3 (or x86-64-v2-AES)." ;;
    host)
      if [[ "$cpu" == *-nested-virt* || "$cpu" == *-vmx* || "$cpu" == *-svm* ]]; then
        good "CPU type host with nested virtualization hidden (Windows cannot start VBS)."
      elif [[ "$nested_host" == "Y" || "$nested_host" == "1" ]]; then
        warn "CPU type 'host' with nested virtualization available: Windows Server 2025 can auto-enable VBS (nested Hyper-V) -> higher CPU cost and sluggishness. Confirm with Server-Audit.ps1. Fix: add flags=-nested-virt, or use CPU type x86-64-v3."
      else
        good "CPU type host; nested virtualization is off on this host."
      fi ;;
    *) good "CPU type '$ctype'." ;;
  esac
  (( nv > HOST_THREADS )) && warn "VM has more vCPUs ($nv) than the host has threads ($HOST_THREADS)."
  (( mem < 8192 )) && info "VM has ${mem} MiB RAM. Windows' file cache (hot CaseWare/TaxCycle files) is bounded by this; the old bare-metal box probably cached far more."
  if [[ -n "$balloon" && "$balloon" != "0" && "$balloon" =~ ^[0-9]+$ ]] && (( balloon < mem )); then
    info "Auto-ballooning enabled (min ${balloon} MiB): the VM can be squeezed under host memory pressure. balloon: 0 is common for file servers."
  fi
  (( sockets > 1 )) && [[ "$numa" != "1" ]] && info "VM has $sockets sockets but NUMA is off."

  if [[ "$agent" == 1* || "$agent" == *enabled=1* ]]; then
    if qm agent "$VMID" ping >/dev/null 2>&1; then good "QEMU guest agent responds."; else info "Guest agent enabled in config but not responding (service not running in Windows?)."; fi
  else
    info "QEMU guest agent not enabled: backups cannot quiesce NTFS (crash-consistent only)."
  fi

  kit_fact vm_vmgenid "$(grep -q '^vmgenid:' <<<"$CONF" && echo yes || echo no)"
  if grep -q '^vmgenid:' <<<"$CONF"; then
    good "vmgenid is set (AD safeguards trigger if this DC VM is rolled back to a snapshot)."
  else
    warn "vmgenid is NOT set. This VM is a domain controller: VM-Generation ID lets AD detect a snapshot rollback/restore and protect itself (critical with more than one DC, recommended with one). Add it: qm set $VMID --vmgenid 1 (effective after a full stop/start)."
  fi

  # Disks
  echo; echo "---- Virtual disks"
  has_scsi=0
  while IFS= read -r line; do
    key=${line%%:*}; val=${line#*: }
    [[ "$key" =~ ^(ide|sata|scsi|virtio)[0-9]+$ ]] || continue
    [[ "$val" == *media=cdrom* || "$val" == none* ]] && continue
    bus=${key%%[0-9]*}; volid=${val%%,*}; opts=",${val},"
    [[ $bus == scsi ]] && has_scsi=1
    echo; echo "$key -> $val"
    kit_fact "disk.$key.config" "$val"
    case $bus in
      ide|sata) warn "$key is on the emulated ${bus^^} bus: very slow for small I/O. Move it to SCSI with scsihw=virtio-scsi-single + iothread=1 (install the VirtIO SCSI driver in Windows first)." ;;
    esac
    if [[ $bus == scsi || $bus == virtio ]]; then
      [[ "$opts" == *",iothread=1,"* ]] || warn "$key: iothread not enabled (for SCSI it also needs scsihw=virtio-scsi-single)."
    fi
    [[ "$opts" == *",discard=on,"* ]] || warn "$key: discard not enabled. The thin zvol never gets back space Windows deletes; enable discard=on and run 'Optimize-Volume -ReTrim' in Windows."
    if [[ $bus != virtio ]]; then
      [[ "$opts" == *",ssd=1,"* ]] || info "$key: ssd=1 not set (Windows treats the disk as a spinning HDD)."
    fi
    cache=$(grep -oE ',cache=[a-z]+' <<<"$opts" | cut -d= -f2)
    case "$cache" in
      ""|none)                good "$key cache=none (recommended on ZFS)." ;;
      writeback)              info "$key cache=writeback: double caching with the ZFS ARC; flushes are still honored, so no gain for sync writes." ;;
      unsafe)                 warn "$key cache=unsafe: ignores flushes - fast, but guest data loss/corruption on a host crash." ;;
      writethrough|directsync) warn "$key cache=$cache: every write is synchronous - very slow for small writes." ;;
    esac
    aio=$(grep -oE ',aio=[a-z_]+' <<<"$opts" | cut -d= -f2)
    echo "aio: ${aio:-default (io_uring)}"
    path=$(pvesm path "$volid" 2>/dev/null)
    echo "backing path: ${path:-?}"
    if [[ "$path" == /dev/zvol/* ]]; then
      ds=${path#/dev/zvol/}
      zfs get -o property,value volblocksize,volsize,referenced,logicalreferenced,refreservation,compressratio,sync,compression,primarycache,logbias "$ds"
      echo "volblocksize=$(zfs get -H -o value volblocksize "$ds")  <- compare with the NTFS cluster size reported by Server-Audit.ps1"
      kit_fact "disk.$key.volblocksize" "$(zfs get -H -o value volblocksize "$ds")"
      kit_fact "disk.$key.zvol" "$ds"
      [[ "$(zfs get -H -o value refreservation "$ds")" == none ]] && echo "thin provisioned (no refreservation)"
      nsnap=$(zfs list -H -t snapshot -o name -r -d 1 "$ds" 2>/dev/null | wc -l)
      kit_fact "disk.$key.snapshots" "$nsnap"
      echo "snapshots on this zvol: $nsnap"
      (( nsnap > 20 )) && info "$key zvol has $nsnap snapshots (space held + metadata overhead)."
    fi
  done <<<"$CONF"
  if (( has_scsi )) && [[ "$scsihw" != virtio-scsi* ]]; then
    warn "SCSI controller is '${scsihw:-lsi (default)}', an emulated controller. Use virtio-scsi-single."
  fi
  [[ "$scsihw" == "virtio-scsi-pci" ]] && info "scsihw=virtio-scsi-pci shares one queue for all disks; virtio-scsi-single enables a dedicated iothread per disk."

  # Network
  echo; echo "---- Network"
  while IFS= read -r line; do
    key=${line%%:*}; val=${line#*: }
    [[ "$key" =~ ^net[0-9]+$ ]] || continue
    model=${val%%=*}
    bridge=$(grep -oE 'bridge=[^,]+' <<<"$val" | cut -d= -f2)
    echo "$key -> $val"
    kit_fact "net.$key.model" "$model"
    case "$model" in
      virtio) good "$key uses the VirtIO NIC." ;;
      e1000|e1000e|rtl8139|vmxnet3|i82551|i82557b|i82559er|ne2k_pci|pcnet)
        warn "$key uses the emulated NIC '$model': more CPU per packet, lower throughput, higher latency. Switch to VirtIO (install the NetKVM driver first)." ;;
    esac
    if [[ $model == virtio && "$val" != *queues=* ]]; then
      info "$key: multiqueue not set (queues=<number of vCPUs>) - spreads many concurrent SMB clients over vCPUs."
    fi
    [[ "$val" == *firewall=1* ]] && info "$key: Proxmox firewall enabled on this NIC (extra bridge + conntrack hop; small overhead - keep it if you rely on it)."
    [[ "$val" == *rate=* ]] && warn "$key has a bandwidth limit (rate=) set."
    if [[ -n "$bridge" && -d /sys/class/net/$bridge/brif ]]; then
      for port in /sys/class/net/"$bridge"/brif/*; do
        p=$(basename "$port")
        [[ -e /sys/class/net/$p/device || -d /sys/class/net/$p/bonding ]] || continue
        spd=$(cat /sys/class/net/"$p"/speed 2>/dev/null || echo "?")
        mtu=$(cat /sys/class/net/"$p"/mtu 2>/dev/null || echo "?")
        echo "    bridge $bridge uplink $p: ${spd} Mb/s, MTU $mtu"
        kit_fact "uplink.$p.mbps" "$spd"
        [[ "$spd" =~ ^[0-9]+$ ]] && (( spd > 0 && spd < 1000 )) && warn "Host uplink $p negotiated only ${spd} Mb/s - check cable / switch port."
      done
    fi
  done <<<"$CONF"
  grep -qE '^hostpci[0-9]+:' <<<"$CONF" && info "VM already has PCI passthrough devices (see hostpci lines)."

  # ------------------------------------------------------ OTHER WORKLOAD
  section "OTHER GUESTS ON THIS HOST (contention)"
  show qm list
  have pct && show pct list

  # -------------------------------------------------- BACKUP/REPLICATION
  section "BACKUP / REPLICATION JOBS (look for anything running during business hours)"
  if [[ -f /etc/pve/jobs.cfg ]]; then cat /etc/pve/jobs.cfg; else echo "no /etc/pve/jobs.cfg"; fi
  [[ -f /etc/pve/vzdump.cron ]] && { echo "--- legacy /etc/pve/vzdump.cron"; grep -v '^#' /etc/pve/vzdump.cron; }
  if [[ -f /etc/pve/jobs.cfg ]] && grep -q '^vzdump:' /etc/pve/jobs.cfg; then
    info "Review the vzdump schedule(s): while a snapshot-mode backup runs, guest writes wait on the backup target. Fleecing (PVE 8.2+) reduces that impact."
    grep -q 'fleecing' /etc/pve/jobs.cfg || info "No backup job uses fleecing."
  fi
  show pvesr status
  echo; echo "VM snapshots:"; qm listsnapshot "$VMID" 2>/dev/null || true

  section "SNAPSHOT / REPLICATION TOOLS (sanoid, syncoid, cron, timers)"
  have sanoid && echo "sanoid: $(sanoid --version 2>/dev/null | head -1)"
  have syncoid && echo "syncoid: $(syncoid --version 2>/dev/null | head -1)"
  if [[ -f /etc/sanoid/sanoid.conf ]]; then echo "--- /etc/sanoid/sanoid.conf"; grep -vE '^[[:space:]]*(#|$)' /etc/sanoid/sanoid.conf | sed 's/^/  /'; fi
  echo "--- timers"; systemctl list-timers --all --no-pager 2>/dev/null | grep -Ei 'sanoid|syncoid|zfs|vzdump|proxmox-backup' | sed 's/^/  /' || true
  echo "--- cron entries"; { crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null; } | grep -Ei 'syncoid|sanoid|zfs send|vzdump' | grep -v '^#' | sed 's/^/  /' || true
  for pool in $(zpool list -H -o name); do
    n=$(zfs list -H -t snapshot -o name -r "$pool" 2>/dev/null | wc -l)
    echo "snapshots in $pool: $n"
    kit_fact "pool.$pool.snapshots" "$n"
  done
  info "Confirm no syncoid/sanoid/scrub job overlaps business hours or Sunday's benchmark window, and take a fresh snapshot + syncoid run right before any change."
  vpnguests=$( { qm list 2>/dev/null; have pct && pct list 2>/dev/null; } | grep -iE 'vpn|openvpn|wireguard|pfsense|opnsense|firewall' )
  [[ -n "$vpnguests" ]] && { echo "--- guests that look like VPN/firewall:"; echo "$vpnguests" | sed 's/^/  /'; info "A VPN/firewall runs on this host: check its NIC model (VirtIO), CPU type (AES-NI) and, for OpenVPN in an LXC, that the DCO module is loaded on the host (run vpn/openvpn-check.sh inside it)."; }
  systemctl list-units --type=service --no-pager 2>/dev/null | grep -qi openvpn && info "An OpenVPN service runs directly on the Proxmox host."

  section "STORAGE DEFINITIONS"
  cat /etc/pve/storage.cfg

  # ------------------------------------------------------------ SUMMARY
  section "SUMMARY OF FINDINGS"
  for f in "${FLAGS[@]}"; do [[ $f == "[WARN]"* ]] && printf '%s\n\n' "$f"; done
  for f in "${FLAGS[@]}"; do [[ $f == "[INFO]"* ]] && printf '%s\n\n' "$f"; done
  for f in "${FLAGS[@]}"; do [[ $f == "[ OK ]"* ]] && echo "$f"; done
  echo; echo "Report saved to: $REPORT"
  kit_fact findings_warn "$(printf '%s\n' "${FLAGS[@]}" | grep -c '^\[WARN\]')"
}

main
