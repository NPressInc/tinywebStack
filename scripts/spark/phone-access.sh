#!/usr/bin/env bash
# Tailscale split-DNS + DNAT so phones reach lab HTTPS on the family VM (spark only).
# Idempotent; requires root. Do not run from CI.
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/scripts/lib/common.sh"

CONF_DIR="/etc/tinywebstack-phone"
DNSMASQ_CONF="${CONF_DIR}/dnsmasq.conf"
DNS_UNIT="tws-phone-dns.service"
NAT_UNIT="tws-phone-nat.service"

TW_VM_IP="${TW_VM_IP:-192.168.122.18}"
TS_IF="${TW_TAILSCALE_IF:-tailscale0}"
LAB_DOMAIN="${TW_PHONE_LAB_DOMAIN:-family.test}"
LAB_NODE="${TW_PHONE_LAB_NODE:-family-b}"

usage() {
  cat <<EOF
Usage: sudo $0 --up|--down

  --up    Start dnsmasq on Tailscale IP + DNAT tcp/80,443 to VM (${TW_VM_IP})
  --down  Stop services and remove NAT rules

Env: TW_VM_IP, TW_TAILSCALE_IF, TW_PHONE_LAB_DOMAIN, TW_PHONE_LAB_NODE
EOF
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    die "Run as root (sudo $0 ...)"
  fi
}

ts_ipv4() {
  require_cmd tailscale
  tailscale ip -4 2>/dev/null | head -n1
}

write_dnsmasq_conf() {
  local ts_ip="$1"
  local fqdn="${LAB_NODE}.${LAB_DOMAIN}"
  mkdir -p "$CONF_DIR"
  cat >"$DNSMASQ_CONF" <<EOF
# Managed by tinywebstack phone-access.sh
bind-dynamic
no-hosts
listen-address=${ts_ip}
port=53
no-resolv
# ${fqdn} and all *.${LAB_DOMAIN} (split DNS on Tailscale)
address=/${LAB_DOMAIN}/${ts_ip}
EOF
}

install_dns_unit() {
  cat >"/etc/systemd/system/${DNS_UNIT}" <<EOF
[Unit]
Description=TinyWeb phone lab DNS (dnsmasq on Tailscale)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=${DNSMASQ_CONF}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

install_nat_unit() {
  cat >"/etc/systemd/system/${NAT_UNIT}" <<EOF
[Unit]
Description=TinyWeb phone NAT (Tailscale -> libvirt VM)
After=network-online.target tailscaled.service
Before=libvirtd.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=TW_VM_IP=${TW_VM_IP}
Environment=TW_TAILSCALE_IF=${TS_IF}
ExecStart=${TW_STACK_ROOT}/scripts/spark/phone-access.sh _nat_up
ExecStop=${TW_STACK_ROOT}/scripts/spark/phone-access.sh _nat_down

[Install]
WantedBy=multi-user.target
EOF
}

_nat_up() {
  local ts_ip
  ts_ip="$(ts_ipv4)"
  [[ -n "$ts_ip" ]] || die "tailscale ip -4 returned nothing"

  if command -v nft >/dev/null 2>&1; then
    nft add table ip tinyweb_phone 2>/dev/null || true
    nft flush table ip tinyweb_phone 2>/dev/null || true
    nft add chain ip tinyweb_phone prerouting '{ type nat hook prerouting priority -100; policy accept; }'
    nft add chain ip tinyweb_phone forward '{ type filter hook forward priority -100; policy accept; }'
    nft add chain ip tinyweb_phone postrouting '{ type nat hook postrouting priority 100; policy accept; }'
    nft add rule ip tinyweb_phone prerouting iifname "${TS_IF}" tcp dport 80 dnat to "${TW_VM_IP}"
    nft add rule ip tinyweb_phone prerouting iifname "${TS_IF}" tcp dport 443 dnat to "${TW_VM_IP}"
    nft add rule ip tinyweb_phone forward iifname "${TS_IF}" oifname virbr0 ip daddr "${TW_VM_IP}" accept
    nft add rule ip tinyweb_phone postrouting oifname virbr0 masquerade
  else
    require_cmd iptables
    iptables -t nat -I PREROUTING 1 -i "${TS_IF}" -p tcp -m multiport --dports 80,443 -j DNAT --to-destination "${TW_VM_IP}"
    iptables -I FORWARD 1 -i "${TS_IF}" -o virbr0 -d "${TW_VM_IP}" -j ACCEPT
    iptables -t nat -I POSTROUTING 1 -o virbr0 -j MASQUERADE
  fi
  log "NAT: ${TS_IF} tcp/80,443 -> ${TW_VM_IP}"
}

_nat_down() {
  if command -v nft >/dev/null 2>&1; then
    nft delete table ip tinyweb_phone 2>/dev/null || true
  else
    require_cmd iptables
    iptables -t nat -D PREROUTING -i "${TS_IF}" -p tcp -m multiport --dports 80,443 -j DNAT --to-destination "${TW_VM_IP}" 2>/dev/null || true
    iptables -D FORWARD -i "${TS_IF}" -o virbr0 -d "${TW_VM_IP}" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o virbr0 -j MASQUERADE 2>/dev/null || true
  fi
}

do_up() {
  require_root
  local ts_ip
  ts_ip="$(ts_ipv4)"
  [[ -n "$ts_ip" ]] || die "tailscale ip -4 returned nothing"

  write_dnsmasq_conf "$ts_ip"
  install_dns_unit
  install_nat_unit

  systemctl daemon-reload
  systemctl enable --now "${DNS_UNIT}"
  systemctl enable --now "${NAT_UNIT}"

  log "Phone access UP: DNS on ${ts_ip} for *.${LAB_DOMAIN} (incl. ${LAB_NODE}.${LAB_DOMAIN}); HTTPS DNAT to ${TW_VM_IP}"
  log "Tailscale admin: DNS -> Add nameserver -> Custom ${ts_ip}, restrict to *.${LAB_DOMAIN}"
}

do_down() {
  require_root
  systemctl disable --now "${NAT_UNIT}" 2>/dev/null || true
  systemctl disable --now "${DNS_UNIT}" 2>/dev/null || true
  _nat_down
  log "Phone access DOWN"
}

case "${1:-}" in
  --up) do_up ;;
  --down) do_down ;;
  _nat_up) _nat_up ;;
  _nat_down) _nat_down ;;
  -h|--help|"") usage ;;
  *) die "Unknown option: $1 (use --up or --down)" ;;
esac
