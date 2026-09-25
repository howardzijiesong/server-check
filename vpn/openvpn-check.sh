#!/bin/sh
# =============================================================================
# openvpn-check.sh - review OpenVPN server/client configs for settings that
#                    make SMB (CaseWare/TaxCycle) over the VPN slow or hang.
# -----------------------------------------------------------------------------
# POSIX sh: runs on Debian/Ubuntu/TurnKey (Linux) and pfSense/OPNsense (FreeBSD).
# READ-ONLY. Run it where the OpenVPN SERVER runs; optionally pass a client
# .ovpn profile too.
#
# Usage:  ./openvpn-check.sh                    # auto-find server configs
#         ./openvpn-check.sh /path/server.conf  /path/client.ovpn
# OpenVPN Access Server keeps its config in a database: use its Admin UI
# (VPN Settings / Advanced / Data Channel Offload) and check the same items.
# =============================================================================

VER="2026.09.25"
# ---- logging: human log (.txt) + machine log (.jsonl) for Analyze-Results.ps1
if [ -z "${OVPNCHK_JSONL:-}" ]; then
  outdir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/results"
  mkdir -p "$outdir" 2>/dev/null && touch "$outdir/.w" 2>/dev/null || outdir=/tmp/openvpn-check-results
  mkdir -p "$outdir"; rm -f "$outdir/.w"
  base="$outdir/openvpn-check-$(hostname | cut -d. -f1)-$(date +%Y%m%d-%H%M%S)"
  OVPNCHK_JSONL="$base.jsonl"; export OVPNCHK_JSONL
  : > "$OVPNCHK_JSONL"
  sh "$0" "$@" 2>&1 | tee "$base.txt"
  echo "Human log: $base.txt"
  echo "Machine log: $OVPNCHK_JSONL  (copy both to the kit's results folder for Analyze-Results.ps1)"
  exit 0
fi
jesc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
rec() { # level key msg [value]
  printf '{"ts":"%s","script":"openvpn-check","ver":"%s","host":"%s","level":"%s","cat":"vpn","key":"%s","msg":"%s","value":"%s","unit":""}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$VER" "$(hostname | cut -d. -f1)" "$1" "$(jesc "$2")" "$(jesc "$3")" "$(jesc "${4:-}")" >> "$OVPNCHK_JSONL"
}
WARN=0
say()  { printf '%s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; WARN=$((WARN + 1)); rec WARN "" "$*"; }
info() { printf '  [INFO] %s\n' "$*"; rec INFO "" "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; rec OK "" "$*"; }
fact() { rec FACT "$1" "" "$2"; }
# value of a directive (first match, comments stripped)
dv()   { sed -e 's/[#;].*$//' "$2" | awk -v k="$1" '$1==k { $1=""; sub(/^ +/, ""); print; exit }'; }
has()  { sed -e 's/[#;].*$//' "$2" | grep -Eq "^[[:space:]]*$1([[:space:]]|\$)"; }

check_file() {
  f=$1
  say ""
  say "=== $f"
  role="client"
  if has server "$f" || has 'mode server' "$f" || has server-bridge "$f"; then role="server"; fi
  say "  role guessed: $role"
  fact "config.$role" "$f"

  proto=$(dv proto "$f"); [ -z "$proto" ] && proto="udp (default)"
  fact "$role.proto" "$proto"
  case "$proto" in
    tcp*) warn "proto $proto: TCP-over-TCP. On any packet loss both layers retransmit and SMB stalls ('TCP meltdown'). Use proto udp (keep a TCP 443 instance only as a fallback for hostile networks)." ;;
    *)    ok "proto $proto" ;;
  esac

  dev=$(dv dev "$f")
  case "$dev" in
    tap*) warn "dev $dev (bridged TAP): broadcast traffic over the tunnel, no DCO. Use dev tun + routing." ;;
    *)    ok "dev ${dev:-?}" ;;
  esac

  topo=$(dv topology "$f")
  if [ "$role" = "server" ] && [ "$topo" != "subnet" ]; then
    warn "topology is '${topo:-net30 (default)}': data channel offload (DCO) requires topology subnet."
  fi

  if has comp-lzo "$f" || has compress "$f"; then
    c=$(dv compress "$f"); l=$(dv comp-lzo "$f")
    if [ -n "$l" ] && [ "$l" != "no" ] || [ -n "$c" ]; then
      warn "compression configured (compress '${c}' / comp-lzo '${l}'): wastes CPU on already-compressed/encrypted data, is a known security weakness, and disables DCO. Remove it and set 'allow-compression no'."
    fi
  fi
  ac=$(dv allow-compression "$f"); [ "$ac" = "yes" ] && warn "allow-compression yes"

  ciph=$(dv cipher "$f"); dcs=$(dv data-ciphers "$f"); [ -z "$dcs" ] && dcs=$(dv ncp-ciphers "$f")
  say "  cipher: ${ciph:-unset}   data-ciphers: ${dcs:-default}"
  fact "$role.cipher" "${ciph:-unset} / ${dcs:-default}"
  case "$ciph" in *CBC*|BF-*|*bf-*) [ -z "$dcs" ] && warn "cipher $ciph without data-ciphers: CBC/Blowfish is slow and cannot use DCO (DCO needs AES-GCM or ChaCha20-Poly1305)." ;; esac
  case "$dcs" in *CBC*) info "data-ciphers still lists a CBC cipher; fine as a fallback for old clients, but make sure clients negotiate AES-GCM." ;; esac

  if has fragment "$f"; then warn "'fragment' is set: extra per-packet overhead and incompatible with DCO. Use mssfix instead."; fi
  ms=$(dv mssfix "$f"); tm=$(dv tun-mtu "$f")
  say "  tun-mtu: ${tm:-default 1500}   mssfix: ${ms:-default}"
  [ -z "$ms" ] && info "mssfix not set explicitly. If Client-NetCheck.ps1 reports a path MTU below 1500 or a black hole, set e.g. 'mssfix 1360' (server; also push it or put it in client profiles)."
  if has disable-dco "$f"; then warn "'disable-dco' is set: the data channel runs in userspace (single-threaded, slower)."; fi

  sb=$(dv sndbuf "$f"); rb=$(dv rcvbuf "$f")
  [ -n "$sb$rb" ] && say "  sndbuf: ${sb:-default}  rcvbuf: ${rb:-default}"
  case "$sb" in ''|0) ;; *) [ "$sb" -lt 262144 ] 2>/dev/null && info "small sndbuf ($sb) can cap throughput on higher-latency links; '0' lets the OS auto-tune." ;; esac

  if [ "$role" = "server" ]; then
    if sed -e 's/[#;].*$//' "$f" | grep -q 'dhcp-option DNS'; then ok "pushes a DNS server (needed for AD / Kerberos over the VPN)";
    else warn "no 'push \"dhcp-option DNS <DC IP>\"': remote PCs may not resolve AD names -> NTLM fallback, slow logons, mapped drives by IP."; fi
    sed -e 's/[#;].*$//' "$f" | grep -q 'dhcp-option DOMAIN' || info "no 'push \"dhcp-option DOMAIN <ad-domain>\"' (DNS suffix for short names like \\\\FS01)."
    if sed -e 's/[#;].*$//' "$f" | grep -q 'redirect-gateway'; then
      info "full tunnel (redirect-gateway): all home internet traffic also crosses the office uplink. Split tunnel (push only office routes) keeps the office upload free for SMB/RDP."
    fi
    ka=$(dv keepalive "$f"); [ -z "$ka" ] && info "no keepalive set (e.g. 'keepalive 10 60')."
  fi
}

say "openvpn-check.sh $VER  $(date 2>/dev/null)  host=$(hostname 2>/dev/null)  os=$(uname -sr)"
rec START args "$*"
fact os "$(uname -sr)"

# ---------------------------------------------------------------- runtime
say ""
say "=== Runtime"
if command -v openvpn >/dev/null 2>&1; then
  v=$(openvpn --version 2>/dev/null | head -1)
  say "  $v"
  fact openvpn_version "$v"
  case "$v" in
    *"OpenVPN 2.4"*|*"OpenVPN 2.5"*|*"OpenVPN 2.3"*) warn "OpenVPN older than 2.6: no data channel offload. Upgrade to 2.6+ (2.7+ if the kernel ships the in-tree 'ovpn' module, Linux 6.16+)." ;;
  esac
  case "$v" in *"[DCO]"*) ok "binary built with DCO support" ;; *) info "binary does not advertise [DCO] support" ;; esac
else
  say "  openvpn binary not found in PATH (Access Server? container? different host?)"
fi
case "$(uname -s)" in
  Linux)
    if lsmod 2>/dev/null | grep -Eq '^ovpn(_dco_v2|_dco)?[[:space:]]'; then ok "DCO kernel module loaded: $(lsmod | awk '/^ovpn/ {print $1}' | xargs)";
    else info "no ovpn/ovpn_dco kernel module loaded (DCO not active). In an LXC container the module must be loaded on the Proxmox HOST."; fi
    grep -qw aes /proc/cpuinfo && ok "CPU has AES-NI" || warn "CPU/VM does not expose AES-NI: AES-GCM runs in software (use ChaCha20-Poly1305 or fix the VM CPU type)."
    say "  CPUs: $(nproc 2>/dev/null)"
    [ -f /run/systemd/container ] && info "running inside a container ($(cat /run/systemd/container))."
    ;;
  FreeBSD)
    kldstat 2>/dev/null | grep -q if_ovpn && ok "FreeBSD if_ovpn (DCO) module loaded" || info "if_ovpn (DCO) not loaded (pfSense Plus / OPNsense: enable DCO per instance)."
    kldstat 2>/dev/null | grep -q aesni && ok "aesni module loaded" || info "aesni kernel module not loaded (pfSense: System > Advanced > Misc > Cryptographic Hardware)."
    ;;
esac
say "  OpenVPN processes (a single process near 100% CPU = the VPN is CPU-bound):"
ps ax -o pid,pcpu,rss,args 2>/dev/null | awk 'NR==1 || /[o]penvpn/' | cut -c1-160 | sed 's/^/    /'

# ---------------------------------------------------------------- configs
FILES="$*"
if [ -z "$FILES" ]; then
  for p in /etc/openvpn/server/*.conf /etc/openvpn/*.conf /etc/openvpn/client/*.conf \
           /var/etc/openvpn/*/config.ovpn /var/etc/openvpn/*.conf /usr/local/etc/openvpn/*.conf; do
    [ -f "$p" ] && FILES="$FILES $p"
  done
fi
if [ -z "$FILES" ]; then
  say ""
  say "No OpenVPN config files found. Pass the server config and/or a client .ovpn as arguments."
else
  for f in $FILES; do [ -r "$f" ] && check_file "$f"; done
fi

say ""
say "Done: $WARN warning(s). DCO needs: OpenVPN 2.6+ on BOTH ends, an AEAD cipher (AES-GCM or"
say "ChaCha20-Poly1305), topology subnet, no compression, no 'fragment'. It speeds the tunnel up;"
say "it cannot remove internet round-trip time, which is what dominates small-file SMB."
rec END status "warnings=$WARN"
