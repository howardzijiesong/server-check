# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A diagnostic kit (no build, no package manager, no test suite) for finding why CaseWare / TaxCycle (many small files over SMB) are slow on one specific setup: Proxmox VE host with ZFS (`FastPool` NVMe mirror, `StoragePool` HDD syncoid target), a single Windows Server 2025 VM that is both DC and file server, and 3-5 remote Windows 11 users on OpenVPN (UDP) from a UniFi gateway. `README.md` is the operator manual (run order, labels, fixes, decisions); `CHECKLIST.md` is the on-site checklist. Keep both in sync with any change to script flags, labels or behaviour.

Scripts run on four kinds of machine: `proxmox/*.sh` on the PVE host as root, `windows/*.ps1` on the server VM (elevated) or on clients (Client-NetCheck and SmallFile-Test must run **non-elevated** on clients to see the user's SMB connections), `vpn/openvpn-check.sh` anywhere POSIX (or on the gateway), and `Analyze-Results.ps1` on the operator's laptop.

## Checking changes

Nothing here can be executed end to end in this container (needs Proxmox, ZFS, Windows, fio, DiskSpd). Useful static checks:

```bash
bash -n proxmox/*.sh                 # syntax
sh -n vpn/openvpn-check.sh           # must stay POSIX sh (also runs on FreeBSD pfSense/OPNsense)
shellcheck proxmox/*.sh vpn/*.sh     # if installed; scripts already carry shellcheck directives
pwsh -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw ./windows/SmallFile-Test.ps1))'   # PS parse check, if pwsh is installed
```

`Analyze-Results.ps1` is the one script that runs off-Windows: to exercise it, hand-write a few `.jsonl` records (schema below) into a folder and run `pwsh ./Analyze-Results.ps1 -Path <folder>` (add `-Redact` to test masking).

## Architecture

### Two-file logging contract (the core design)
Every script writes `results/<Script>-<HOST>-<timestamp>.txt` (human log) and `.jsonl` (machine log) next to itself, via the shared libraries:

- `proxmox/kit-common.sh` (sourced by the three `pve-*.sh`): `kit_init`, `kit_section`, `kit_rec`, `kit_fact`, `kit_metric`, `kit_error`/`kit_die`, `kit_require_*` preflight checks, `kit_ensure_cmd`, and an EXIT trap that calls an optional `kit_cleanup` function then writes the END record.
- `windows/lib/KitCommon.ps1` (dot-sourced by every `windows/*.ps1`): `Initialize-KitLog`, `Section`, `Write-KitRecord`, `Add-Finding`, `Write-KitFact`, `Write-KitMetric`, `Write-KitError` (auto-derives a `hint:` from the exception via `Get-KitErrorHint`), `Assert-KitAdmin`, `Complete-KitLog`.
- `vpn/openvpn-check.sh` is standalone (no shared lib): it re-execs itself through `tee` and has its own `rec()` writer emitting the same schema.

JSONL record: `{"ts","script","ver","host","level","cat","key","msg","value","unit"}`, one per line. Levels: `START END OK INFO WARN ERROR FACT METRIC`. A run with no END record is reported as "did not finish". `KIT_VERSION` / `$script:KitVersion` / `VER` in the three writers carry the same date-style version.

Errors are always printed as `ERROR: <msg>` followed by `  hint: <fix>` and logged as an ERROR record; the README troubleshooting table and `Analyze-Results.ps1` rely on that format.

### Analyzer coupling (easy to break)
`Analyze-Results.ps1` loads every `*.jsonl` under `-Path` and matches records **by `cat` and `key` strings**. Renaming a category, metric key or label in a producer script silently drops it from the summary. Current contracts include:

- `cat` prefixes: `smallfile/<label>`, `diskbench/<label>`, `pvebench/pool`, `pvebench/device`, `pvemonitor`, `perf/server`, `perf/client`, `netcheck/<label>`, `vpn` (all openvpn-check records). Otherwise `cat` is the slugified `Section` / `kit_section` title (lowercase, non-alnum -> `_`, max 40 chars), so renaming a section heading also changes its `cat`.
- Metric keys such as `<Phase>.ms_per_file` / `<Phase>.roundtrips_per_file` (SmallFile-Test), `zvol-<vbs>-randwrite-4k-qd1-sync.w_lat_avg_us`, `zfs_overhead_sync_write_x`, `disk_worst_p95_ms`, `rtt_ms`, `ping_loss_pct`; facts such as `primary_volblocksize`, `pmtu_blackhole`, `kerberos_ticket`.
- Hard-coded SmallFile labels that line up the latency ladder: `server-local`, `server-local+AVexcl` (produced by `-DefenderAB`), `server-loopback`, `lan-client`, `vpn-client`, `vpn-client-wg`, `vpn-client-hdd`. DiskBench labels matching `hdd|ssd|native|usb|test` are excluded from the "production disk" verdict.
- Some verdicts grep WARN message text (`HasWarn` / `WarnText` regexes), so rewording a WARN can change the analysis.

When adding a new measurement, add the producer record and the analyzer consumer together, and document any new label in README section 2/4.

### Safety model
Most scripts are read-only. The exceptions and their guard rails must be preserved:
- `pve-bench.sh` pool mode creates temporary `<parent>/zz-bench-<vbs>` zvols one at a time and destroys them in `kit_cleanup` (also on Ctrl+C); raw pool members are only ever read.
- `pve-bench.sh -D <device>` **wipes** the device and builds a temporary pool `zzbench`; it always requires a typed confirmation (even with `-y`). `-K` keeps `zzbench/winvol`.
- `SmallFile-Test.ps1` writes only under `_smallfile_bench\`; `Server-DiskBench.ps1` writes a temp file filled with incompressible data (so ZFS compression / thin holes don't inflate results); `Perf-Monitor.ps1` creates and removes a temporary logman collector.

## Conventions

- **Line endings are enforced by `.gitattributes`:** `*.sh` LF, `*.ps1` CRLF. Every bash script begins with a CRLF self-check whose lines end in a trailing ` #` (so the guard still parses if `\r` is present) - keep that pattern in new scripts.
- Bash scripts: `#!/usr/bin/env bash`, re-exec under bash if run via `sh`, `set -uo pipefail` (deliberately not `-e`; failures go through `kit_error`), locate `kit-common.sh` via `SCRIPT_DIR` and fail with a "copy the whole folder" message if missing. `usage()` prints the header comment via `sed -n '2,Np' "$0"`, so update N when the header block changes length.
- PowerShell: must run on **Windows PowerShell 5.1** and PowerShell 7; ASCII only in `.ps1` files; `$ErrorActionPreference = 'Continue'` (native-exe stderr + `Stop` is fatal in 5.1); comment-based help (`.SYNOPSIS`/`.EXAMPLE`) at the top; results default to `(Join-Path $PSScriptRoot 'results')`. `Analyze-Results.ps1` must also work under `pwsh` on Linux and parses numbers with `InvariantCulture`.
- Test output contains host names, users, IPs and share names: `results/`, `collected/`, `*.jsonl`, `*.blg` and `analysis-summary-*.md` are git-ignored and must never be committed. DiskSpd binaries are not committed either (`windows/tools/` is ignored except the placeholder note).
