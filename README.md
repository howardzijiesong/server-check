# CaseWare / TaxCycle slowness - bottleneck kit

Scripts to find out **where the time goes** when CaseWare Working Papers and TaxCycle (thousands of small files on an SMB share) are slow, on a Proxmox + Windows Server 2025 setup. They also produce a plain-English analysis with prioritized next steps.

**Environment this kit was written for:**
- **Host:** Proxmox VE (updated June 2026) on an AMD EPYC Rome 32-core CPU with 256 GB RAM (ASRock Rack board, 10 GbE). It boots from a separate Intel enterprise SSD.
- **FastPool:** a ZFS mirror of 2x Kioxia CD6 NVMe. It holds the Windows VM and 4 rarely used VMs.
- **StoragePool:** HDD backup target, replicated with syncoid nightly at 04:00 (30 daily / 8 weekly / 6 monthly / 8 yearly retention, a compliance requirement).
- **Windows VM:** a single Windows Server 2025 VM that is both the **domain controller and the file server**. Its data is on ZFS thin zvols formatted NTFS. An old NTFS HDD is also attached directly to the VM, with no ZFS.
- **Clients:** Windows 11. 3-5 remote users connect from their own computers over OpenVPN (Fortinet until last week). SmartSync is ruled out.
- **Power:** consumer UPS for now; an enterprise UPS is planned.

> Remote access was slow under **every** setup, including the old bare-metal server and the Fortinet VPN. That points at the architecture (small-file SMB over the internet), not at one VPN product or one storage layout. The kit measures this directly.

---

## 1. What's in the kit

| File | Run on | Purpose | Changes anything? |
|---|---|---|---|
| `proxmox/pve-audit.sh <vmid>` | Proxmox host | Host / NVMe / ZFS / VM config audit, sanoid/syncoid timers, vmgenid | No |
| `proxmox/pve-bench.sh -m <vmid> -k <disk>` | Proxmox host | fio: raw NVMe (read-only) + temporary test zvols (volblocksize, sync cost) | Temporary `zz-bench-*` zvols only |
| `proxmox/pve-bench.sh -D <blank ssd> [-K]` | Proxmox host | **Same-SSD test: raw device vs ZFS zvol on that same device** | **WIPES that SSD** (typed confirmation) |
| `proxmox/pve-monitor.sh -p FastPool -m <vmid> -t 0` | Proxmox host | Records ZFS latency / CPU / I/O pressure during real use | No |
| `windows/Server-Audit.ps1 -DataPath D:\...` | Server VM (admin) | VBS, VirtIO, NTFS, SMB/shares, AV/EDR, shadow copies, event logs | No |
| `windows/Server-DiskBench.ps1 -TestPath X:\_bench -Label <name>` | Server VM (admin) | DiskSpd on any volume (zvol disk, old HDD, test SSD) | Temporary test file |
| `windows/SmallFile-Test.ps1 -Path <local/UNC> -Label <layer>` | Server + clients | The same small-file workload at every layer; optional Defender A/B | Only under `_smallfile_bench\` |
| `windows/Client-NetCheck.ps1 -Server <name> -Share <share>` | Clients (non-admin) | Latency, loss, MTU black hole, OpenVPN adapter, SMB signing, Kerberos | No |
| `windows/Perf-Monitor.ps1 -Role Server\|Client -Label lan\|vpn` | Server + a client (admin) | Performance counters during real use, with verdicts | Temporary logman collector |
| `vpn/openvpn-check.sh [configs]` | OpenVPN server (Linux / pfSense / OPNsense) | TCP mode, compression, CBC, DCO, MTU, DNS push, full tunnel | No |
| `Analyze-Results.ps1 -Path <folders> [-Redact]` | Your laptop / any PowerShell | **Reads every log and writes the summary + next steps** | Writes `analysis-summary-*.md` |

Shared libraries: `proxmox/kit-common.sh` and `windows/lib/KitCommon.ps1`. **Always copy whole folders**, never single scripts.

## 2. Logging and analysis

Every run writes two files into a `results/` folder next to the script:

- `<Script>-<HOST>-<timestamp>.txt` is the human-readable log: everything you saw on screen.
- `<Script>-<HOST>-<timestamp>.jsonl` is the machine log: one JSON record per finding (OK/INFO/WARN), fact, metric and error, plus START/END records.

Runs that crash or are interrupted show up as "did not finish".

At the end of the day, collect everything in one place:
```powershell
# on your laptop, in the kit folder:
scp -r root@<pve>:/root/kit/proxmox/results .\collected\proxmox
# copy windows\results from the server + each client (USB), and vpn/results from the firewall
.\Analyze-Results.ps1 -Path .\collected                 # full summary for you
.\Analyze-Results.ps1 -Path .\collected -Redact         # same, with names/IPs masked - safe to share
```

The summary contains:
- a plain-English verdict on storage and remote access, and whether rebuilding the pool is justified
- where a remote file read's milliseconds go (disk, SMB, LAN, VPN)
- failed or unfinished tests, with fix hints
- a prioritized next-steps list
- all warnings and the configuration facts

It runs in Windows PowerShell 5.1 and in PowerShell 7 (`pwsh`) on Linux.

**Use these labels so the analyzer can line the layers up:** `server-local`, `server-loopback`, `lan-client`, `vpn-client`. Optional extra labels: `hdd-native`, `ssd-native`, `ssd-zfs`, `vpn-client-hdd`.

## 3. Prep before Sunday

1. Copy the kit to a USB stick and your laptop. Put the extracted `DiskSpd.zip` (github.com/microsoft/diskspd/releases) into `windows/tools/`.
2. Bring the latest virtio-win ISO and a phone hotspot (to test the real VPN path from on site).
3. Bring the test SSD, attached via **SATA or NVMe, not USB**. USB adds its own bottleneck. It will be wiped.
4. Proxmox host:
   - `scp -r proxmox vpn root@<pve>:/root/kit/`
   - `chmod +x /root/kit/*/*.sh`
   - Check that `apt install fio nvme-cli` works.
5. Windows: if blocked, run `Get-ChildItem -Recurse *.ps1 | Unblock-File`, then use `powershell -ExecutionPolicy Bypass -File <script>`.
6. Pick one slow CaseWare engagement and one slow TaxCycle return as fixed before/after test cases.

## 4. Sunday run order

### Step 0 - Safety net
```bash
qm config <vmid> > /root/vm<vmid>-before-$(date +%F).conf
zfs snapshot -r FastPool@pre-sunday-$(date +%F)     # instant rollback point (same pool - not a backup)
# run the normal syncoid job by hand, then confirm the newest snapshot arrived:
zfs list -t snapshot -o name,creation -s creation -r StoragePool | tail
```
- Roll back one zvol at a time with the VM stopped: `zfs rollback FastPool/<...>/vm-<vmid>-disk-N@pre-sunday-<date>`.
- Avoid `rollback -r`: it deletes newer snapshots, including sanoid's.
- The VM is the DC, so make sure `vmgenid` is set (pve-audit checks this).

### Step 1 - Audits (read-only, anytime)
`./pve-audit.sh <vmid>` · `.\Server-Audit.ps1 -DataPath D:\<data>` · `./openvpn-check.sh` (on the VPN box, plus a client .ovpn)

### Step 2 - Benchmarks (users off)
| What | Command |
|---|---|
| Host layers | `./pve-bench.sh -m <vmid> -k <data disk>` (about 15-20 min; `-q` about 5) |
| VM on the zvol disk | `.\Server-DiskBench.ps1 -TestPath D:\_bench -Label zvol-fastpool` |
| VM on the old HDD (no ZFS) | `.\Server-DiskBench.ps1 -TestPath E:\_bench -Label hdd-native -Quick` |
| Seed set (server) | `.\SmallFile-Test.ps1 -Path D:\Share -Label seed -Mode Seed` |
| server-local | `.\SmallFile-Test.ps1 -Path D:\Share -Label server-local -DefenderAB` |
| server-loopback | `.\SmallFile-Test.ps1 -Path \\<server>\Share -Label server-loopback` |
| lan-client (office PC) | `.\SmallFile-Test.ps1 -Path \\<server>\Share -Label lan-client -Mode ReadSeed` |
| vpn-client (laptop on hotspot + OpenVPN) | `.\SmallFile-Test.ps1 -Path \\<server>\Share -Label vpn-client -Mode ReadSeed -RealDataPath \\<server>\Share\<engagement>` |
| Network, both locations | `.\Client-NetCheck.ps1 -Server <server> -Share <share>` |

### Step 3 - Same-media "ZFS vs no ZFS" test with the SSD you bring
1. Host: `./pve-bench.sh -D /dev/disk/by-id/<ssd> -m <vmid> -k <data disk> -K`
   - Raw-device tests, then the same tests on a zvol in a temporary pool `zzbench` on that SSD.
   - `-K` keeps a `zzbench/winvol` zvol afterwards.
2. Windows on SSD **with** ZFS:
   - Run `qm set <vmid> --scsi9 /dev/zvol/zzbench/winvol,backup=0,iothread=1,discard=on,ssd=1`.
   - Initialize the disk in Windows and format it NTFS.
   - Run DiskBench + SmallFile-Test with `-Label ssd-zfs`.
3. Windows on SSD **without** ZFS:
   - Run `qm set <vmid> --delete scsi9`, then `zpool destroy zzbench`, then `wipefs -a <ssd>`.
   - Run `qm set <vmid> --scsi9 /dev/disk/by-id/<ssd>,backup=0,iothread=1,discard=on,ssd=1`, and format NTFS again.
   - Run the tests with `-Label ssd-native`.
4. Detach at the end with `qm set <vmid> --delete scsi9`.
5. Optional, and the best demonstration for the client: share a folder on the old HDD and run SmallFile-Test over the VPN against it with `-Label vpn-client-hdd`. If that VPN number is about the same as the NVMe share's, the storage medium doesn't matter remotely.

Caveat: a consumer SSD without power-loss protection is slow at flushes, which exaggerates ZFS's sync-write cost compared with the CD6. Its *read* comparison is fair.

### Step 4 - Real use, recorded (with a user, on LAN and over VPN)
Start the recorders, open the test engagement/return, and note the clock time of each hang:
- `./pve-monitor.sh -p FastPool -m <vmid> -t 0`
- `.\Perf-Monitor.ps1 -Role Server -Minutes 0 -Label vpn`
- `.\Perf-Monitor.ps1 -Role Client -Minutes 0 -Label vpn`

### Step 5 - Fix, re-measure, analyze
Apply section 6 fixes, re-run steps 2 and 4 identically, then run `Analyze-Results.ps1`.

## 5. Reading the results (the analyzer does this for you)

| Compare | If the second is much worse... |
|---|---|
| host zvol 4K sync write -> VM DiskSpd 4K write-through | VM config (controller / iothread / CPU type / VBS). Good VMs are about 2-4x the host |
| raw SSD -> zvol on the same SSD (`-D`) | The real cost of ZFS on identical media |
| hdd-native / ssd-native vs zvol-fastpool (VM) | What "no ZFS" buys inside Windows |
| server-local -> server-local+AVexcl (faster) | Defender cost on the server |
| server-local -> server-loopback | SMB stack (signing, DC hardening, CPU) |
| server-loopback -> lan-client | LAN / client AV |
| lan-client -> vpn-client | VPN + internet round trips |

Rules of thumb:
- 4K write-through in the VM: under 0.3 ms excellent, over 3 ms poor.
- Disk P95 during real use: under 2 ms means storage is not the bottleneck; over 10 ms means it is.
- About 2-4 round trips per file at 20+ ms RTT means network-bound.

## 6. Fixes, in order (details and trade-offs)

**A. VM configuration (needs VM shutdown; reversible).**
1. Install the virtio-win guest tools first.
2. `scsihw: virtio-scsi-single`, and on every disk `iothread=1,discard=on,ssd=1`, cache none.
   - For the boot disk, add a temporary SCSI disk first so Windows loads vioscsi.
3. CPU type `x86-64-v3` or `host,flags=-nested-virt`. This stops VBS; you lose Credential Guard / HVCI.
4. VirtIO NIC with `queues=<vCPUs>`. **It's the DC:** record `ipconfig /all` and re-enter the static IP.
5. `balloon: 0`, and `vmgenid` present.

**B. Windows.**
- Defender exclusions for the data folders and the CaseWare/TaxCycle processes and extensions, on the server and workstations. Trade-off: those files are no longer scanned on access.
- `fsutil 8dot3name set D: 1`, then `fsutil behavior set disablelastaccess 1`.
- ABE off if not needed; shadow copies outside business hours; `Optimize-Volume -ReTrim`.

**C. OpenVPN (3-5 users).**
- `proto udp`.
- DCO: 2.6+ on both ends, AES-GCM / ChaCha20-Poly1305, `topology subnet`, no compression, no `fragment`.
- `mssfix` if an MTU problem shows up.
- Push the DC as DNS plus the domain suffix; split tunnel.

These fix hangs and throughput, not round-trip time.

**D. Storage (only if real-use disk latency is high).**
- New zvol with the best volblocksize from pve-bench: add it as a new disk, then `robocopy /MIR /COPYALL /DCOPY:DAT`, then swap letters and shares.
- `sync=disabled` only **after** the enterprise UPS is installed *and* wired for automatic shutdown (NUT on Proxmox). Until then the risk is losing the last seconds of "saved" work on a power cut.

## 7. Decisions

### Rebuild FastPool as plain NTFS (NVMe passthrough)?
Technically possible, since Proxmox boots from the Intel SSD, but:
- **You lose the syncoid chain and its 8-year retention.** A new Windows-level backup system meeting the same rules would be needed.
- You also lose Proxmox snapshots/backups of that data and ZFS checksums/self-healing.
- The 4 other VMs must move.
- It's a destructive rebuild.
- **It does nothing for remote users.**

Only consider it if **all** of these hold:
1. Real-use disk P95 is over about 10 ms.
2. `-D` shows a large ZFS penalty on reads.
3. The tuning in 6D fails.

### Remote users (3-5, on their own computers, SmartSync ruled out)
Over any VPN, each small file costs several internet round trips. The fix that works for *both* apps is to **run them next to the data**.

| Option | Gains | Costs / risks |
|---|---|---|
| **Remote Desktop Session Host VM** (separate from the DC) | Near-office speed for CaseWare + TaxCycle. Client data stays on the server instead of being pulled onto personal PCs. One place to patch. Easily sized on this host | RDS CALs for 3-5 users. Windows Server licensing for the extra VM (verify core licensing with your reseller). Printer/scanner redirection quirks. Confirm both vendors' terminal-server licensing. 120-day grace period for a pilot |
| Tune OpenVPN only | Fixes hangs, loss, MTU | Still round-trip-bound: slow |
| CaseWare Cloud | No VPN for CaseWare | Subscription; CaseWare only |

### DC and file server on one VM
Splitting them is not a speed fix by itself (signing happens anyway with Windows 11 24H2). It is best practice, and required before adding a Remote Desktop host, which shouldn't run on a DC.

## 8. Troubleshooting common errors

| Symptom | Fix |
|---|---|
| `env: 'bash\r': No such file` / `$'\r': command not found` | Windows line endings: `sed -i 's/\r$//' /root/kit/*/*.sh` |
| `Permission denied` running a `.sh` | `chmod +x *.sh`, or run `bash script.sh` (noexec USB mounts) |
| `kit-common.sh is missing` / `KitCommon.ps1 is missing` | Copy the whole `proxmox/` or `windows/` folder |
| apt: `401 Unauthorized` installing fio | Enterprise repo without a subscription: enable `pve-no-subscription` |
| `pool 'fastpool' not found` | Names are case-sensitive: `FastPool` |
| `running scripts is disabled` | `powershell -ExecutionPolicy Bypass -File .\<script>.ps1` and `Unblock-File` |
| "must run elevated" | Right-click PowerShell, then Run as administrator (server scripts, Perf-Monitor) |
| Client scripts can't see the share or mapped drives | Run Client-NetCheck / SmallFile-Test **non-elevated**; elevated sessions don't see the user's connections |
| Share not reachable | Check the `\\server\share` spelling, that the VPN is up, and that it opens in Explorer as DOMAIN\user |
| DiskSpd failed / blocked | Put `diskspd.exe` in `windows/tools`, allow it in AV, run elevated |
| Perf-Monitor summary missing | Run it in `powershell.exe` (5.1), or later `-Summarize <file.blg>` |
| Counter sets "not present" | Non-English Windows uses translated counter names; use PerfMon manually |

Every script also prints `ERROR:` lines with a `hint:`, and logs them for the analyzer.

## 9. GitHub

The scripts contain no client data, so the kit itself can go in a repository. Test **results** contain server names, users, IPs and share names: `.gitignore` keeps `results/` and summaries out. **Never commit results to a public repo.**

```bash
git init && git add . && git commit -m "bottleneck kit"
gh repo create <name> --public --source=. --push      # or --private
```

Getting help if something breaks:
- **Public repo:** paste the repo URL into a chat with Claude. Claude can clone and read it, then hand back fixed files for you to commit. It cannot push, and it cannot watch the repo between messages.
- **Private repo:** attach the script, or the kit zip, directly in the chat.
- Results: run `Analyze-Results.ps1 -Redact` and paste the summary. For a script error, paste the `ERROR:` + `hint:` lines, or attach the `.txt` log.
