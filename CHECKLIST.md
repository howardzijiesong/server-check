# Sunday on-site checklist

Tick items as you go. "Audit" means the item is reported by `pve-audit.sh` or `Server-Audit.ps1`.

## Before leaving home
- [ ] Kit on USB + laptop; DiskSpd in `windows/tools/`; latest virtio-win ISO
- [ ] Credentials: Proxmox root, domain admin, OpenVPN server/firewall admin, one normal test user
- [ ] Phone hotspot + OpenVPN profile on your laptop (to test the real remote path on site)
- [ ] Know the VMID, the data disk key (e.g. `scsi1`), share names and data paths
- [ ] Pick one slow CaseWare engagement and one slow TaxCycle return as the fixed test cases
- [ ] Test SSD in the bag, attachable via SATA or NVMe (not USB); it will be wiped by `pve-bench.sh -D`
- [ ] Consumer UPS today: no sync=disabled until the enterprise UPS + automatic shutdown (NUT) exists
- [ ] Laptop has PowerShell (Windows) or pwsh (Arch) to run `Analyze-Results.ps1` at the end

## Safety net (do first, on site)
- [ ] `qm config <vmid>` saved to a file
- [ ] `zfs snapshot -r FastPool@pre-sunday-<date>`
- [ ] Manual syncoid run to StoragePool completed; newest snapshot visible on StoragePool
- [ ] `vmgenid` present in the VM config (DC rollback protection)
- [ ] No scrub / trim / syncoid running during benchmarks (`zpool status`, timers in the audit)
- [ ] `ipconfig /all` of the server saved (needed if the NIC model changes)

## Proxmox host (EPYC Rome / ASRock Rack)
- [ ] BIOS: Determinism = Performance, NPS reviewed, Global C-state control reviewed, SR-IOV/IOMMU state noted
- [ ] CPU governor `performance` (audit)
- [ ] NVMe links at the drives' full speed/width; SMART clean, no media errors (audit)
- [ ] 10 GbE uplink negotiated at 10000 Mb/s (audit)
- [ ] FastPool: ashift 12, under 80% full, dedup off, sync=standard (audit)
- [ ] No kernel NVMe timeouts/resets (audit)
- [ ] ARC size sensible for 256 GB RAM; no host swapping (audit)
- [ ] Snapshot counts reasonable; sanoid/syncoid schedule outside business hours (audit)
- [ ] Other VMs/containers on FastPool noted (contention)

## VM hardware (Proxmox config) - fix after the baseline
- [ ] virtio-win guest tools installed first (drivers + QEMU guest agent)
- [ ] `scsihw: virtio-scsi-single`; every disk `iothread=1,discard=on,ssd=1`, cache none
- [ ] No disk on IDE/SATA
- [ ] CPU type `x86-64-v3` or `host,flags=-nested-virt` (no VBS on nested Hyper-V)
- [ ] NIC model `virtio`, `queues=<vCPUs>`; static IP/DNS re-entered if the adapter changed
- [ ] `balloon: 0`; RAM sized generously (the file cache lives here)
- [ ] Guest agent enabled and responding

## Windows Server 2025 (DC + file server)
- [ ] VBS status = Off / not running (audit)
- [ ] VirtIO drivers current; RSS enabled on the VirtIO NIC (audit)
- [ ] Power plan High performance
- [ ] TRIM enabled; `Optimize-Volume -DriveLetter <X> -ReTrim` run once after enabling discard
- [ ] NTFS cluster size noted vs zvol volblocksize (audit)
- [ ] 8.3 names off on the data volume; last-access updates off
- [ ] No events 129/153 (storage resets) or SMBServer 1020 (audit)
- [ ] Shadow copies not scheduled during business hours
- [ ] No pending reboot

## SMB and shares
- [ ] SMB1 off; leasing and oplocks on (audit)
- [ ] Signing state noted (required anyway by Windows 11 24H2 clients and by the DC role)
- [ ] Share encryption off unless required; not Continuously Available (audit)
- [ ] Access-based enumeration off unless needed
- [ ] Clients map drives by server NAME (Kerberos), not IP

## Antivirus / EDR
- [ ] Defender exclusions on the server for the data folders + CaseWare/TaxCycle extensions/processes
- [ ] Same exclusions on workstations (CaseWare recommends both)
- [ ] Third-party EDR / ThreatLocker filters reviewed (`fltmc filters` in the audit)
- [ ] `SmallFile-Test.ps1 -DefenderAB` result recorded (evidence for or against exclusions)

## OpenVPN (the remote-user pain point)
- [ ] Where it runs noted (firewall appliance / LXC / VM / host) and its version (2.6+ for DCO)
- [ ] `proto udp` (TCP only as a fallback instance)
- [ ] Data channel offload active: AEAD cipher (AES-GCM / ChaCha20-Poly1305), `topology subnet`, no compression, no `fragment`
- [ ] LXC on Proxmox: DCO module available on the host kernel
- [ ] CPU of the VPN endpoint exposes AES-NI; the OpenVPN process is not pegged at 100%
- [ ] `mssfix` set if Client-NetCheck finds a path MTU below 1500 or a black hole
- [ ] Pushes the DC as DNS + the AD domain suffix; remote PCs get Kerberos tickets
- [ ] Split tunnel (office routes only) unless policy requires full tunnel
- [ ] Office upload bandwidth and a typical remote user's latency recorded
- [ ] Windows clients use the DCO adapter rather than legacy TAP-Windows (Client-NetCheck)

## Clients (Windows 11)
- [ ] Build noted (24H2+ = signing required)
- [ ] SMB client caches not disabled (Client-NetCheck)
- [ ] Offline Files not caching the data share
- [ ] Wired rather than Wi-Fi in the office where possible
- [ ] CaseWare: file tracking under Tools | Options | Data Store disabled for remote users

## Same-media comparisons (the SSD you bring + the old HDD)
- [ ] `pve-bench.sh -D /dev/disk/by-id/<ssd> -m <vmid> -k <disk> -K` (raw vs ZFS on the same SSD)
- [ ] Windows on the SSD via ZFS (`-Label ssd-zfs`) and natively (`-Label ssd-native`)
- [ ] Old HDD: `Server-DiskBench.ps1 -TestPath E:\_bench -Label hdd-native -Quick`
- [ ] Old HDD over VPN: SmallFile-Test against a share on it, `-Label vpn-client-hdd`
- [ ] SSD detached (`qm set <vmid> --delete scsi9`), `zzbench` pool destroyed

## Measure (same tests before and after every change)
- [ ] pve-bench (host) and Server-DiskBench (VM)
- [ ] SmallFile-Test ladder: server-local (+AV A/B), server-loopback, lan-client, vpn-client (ReadSeed + RealDataPath)
- [ ] Client-NetCheck on a LAN PC and on the VPN laptop
- [ ] Perf-Monitor (server + client) and pve-monitor while a user opens the test engagement/return, on the LAN and over the VPN
- [ ] Stopwatch time to open the test engagement and return, LAN and VPN

## Collect and analyze (end of day)
- [ ] Copy `proxmox/results` from the host (scp), `windows/results` from the server and each client, `vpn/results` from the VPN box
- [ ] `Analyze-Results.ps1 -Path <collected folder>`; read the next-steps list
- [ ] `-Redact` version saved if you want to share it (chat / GitHub issue)
- [ ] Results NOT committed to any public repository

## Decision gates
- [ ] **Storage rebuild?** Only if disk P95 over about 10 ms during real use AND the zvol is far behind raw NVMe AND tuning failed. Passthrough or LVM would break the syncoid chain and its 8-year retention.
- [ ] **VM config problem?** If host zvol sync latency is fine but VM write-through is many times worse: fix the VM config, not ZFS.
- [ ] **Remote users (3-5, own PCs)?** If the analyzer says most remote time is the VPN path, plan app-next-to-data: a Remote Desktop session host VM, separate from the DC (120-day grace period for a pilot; client data stays on the server).
- [ ] **Clean up:** delete `_smallfile_bench`, and the `pre-sunday` snapshot once satisfied (after the next syncoid run).
