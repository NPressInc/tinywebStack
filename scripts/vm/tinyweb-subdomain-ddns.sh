#!/usr/bin/env bash
# Dynamic DNS + single-SAN/wildcard TLS helper for <family>.tinyweb.win nodes.
set -euo pipefail

SCRIPT_VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_VM_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${REPO_ROOT}/scripts/lib/domains.sh"
# shellcheck source=scripts/lib/tinyweb-install-env.sh
source "${REPO_ROOT}/scripts/lib/tinyweb-install-env.sh"

DRY_RUN=0
DO_CHECK=0
DO_INSTALL_TIMER=0
DO_PROVISION_SAN=0
FAMILY_RAW=""
BASE_DOMAIN="${TWS_BASE_DOMAIN:-tinyweb.win}"
IPV4=""
IPV6=""

usage() {
  cat <<'EOF'
Usage: tinyweb-subdomain-ddns.sh --family <slug> | --domain <domain> [options]

Options:
  --base-domain <base>   Base domain (default: tinyweb.win / TWS_BASE_DOMAIN)
  --ipv4 <addr>          IPv4 for A records (default: detect)
  --ipv6 <addr>          IPv6 for AAAA records (optional)
  --dry-run              Print planned updates; no network or root changes
  --check                Verify DNS for family + service hostnames
  --install-timer        Install systemd timer for periodic DDNS updates
  --provision-san-cert   Issue one LE cert for apex + wildcard and link per service domain
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --family|--domain)
      FAMILY_RAW=$2
      shift 2
      ;;
    --base-domain)
      BASE_DOMAIN=$2
      shift 2
      ;;
    --ipv4)
      IPV4=$2
      shift 2
      ;;
    --ipv6)
      IPV6=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --check)
      DO_CHECK=1
      shift
      ;;
    --install-timer)
      DO_INSTALL_TIMER=1
      shift
      ;;
    --provision-san-cert)
      DO_PROVISION_SAN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$FAMILY_RAW" ]] || usage

MAIN_DOMAIN="$(resolve_tws_domain "$FAMILY_RAW" "$BASE_DOMAIN")"
WILDCARD_DOMAIN="*.${MAIN_DOMAIN}"

ddns_provider() {
  if [[ -n "${TWS_DDNS_ENDPOINT:-}" && -n "${TWS_DDNS_TOKEN:-}" ]]; then
    printf 'webhook'
  elif [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
    printf 'cloudflare'
  else
    printf 'none'
  fi
}

san_domains_line() {
  local d
  local -a parts=("$MAIN_DOMAIN" "$WILDCARD_DOMAIN")
  while read -r d; do
    [[ -n "$d" ]] || continue
    [[ "$d" == "$MAIN_DOMAIN" ]] && continue
    parts+=("$d")
  done < <(node_all_domains "$MAIN_DOMAIN")
  local IFS=,
  printf '%s' "${parts[*]}"
}

print_dry_run_summary() {
  printf 'domain=%s\n' "$MAIN_DOMAIN"
  printf 'wildcard=%s\n' "$WILDCARD_DOMAIN"
  printf 'san_domains=%s\n' "$(san_domains_line)"
  printf 'provider=%s\n' "$(ddns_provider)"
}

detect_public_ipv4() {
  if [[ -n "$IPV4" ]]; then
    printf '%s' "$IPV4"
    return 0
  fi
  curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true
}

ddns_update_webhook() {
  local v4=$1
  local v6=${2:-}
  require_cmd curl
  local payload
  payload=$(printf '{"token":"%s","domain":"%s","wildcard":"%s","ipv4":"%s","ipv6":"%s"}' \
    "$TWS_DDNS_TOKEN" "$MAIN_DOMAIN" "$WILDCARD_DOMAIN" "$v4" "$v6")
  curl -fsSL --max-time 30 -X POST \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$TWS_DDNS_ENDPOINT"
}

cf_api() {
  local method=$1
  local path=$2
  local data=${3:-}
  local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}${path}"
  if [[ -n "$data" ]]; then
    curl -fsSL --max-time 30 -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$data" \
      "$url"
  else
    curl -fsSL --max-time 30 -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      "$url"
  fi
}

cf_upsert_record() {
  local name=$1
  local type=$2
  local content=$3
  local existing id
  id="$(cf_api GET "/dns_records?type=${type}&name=${name}" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for r in data.get('result',[]):
    if r.get('name')==sys.argv[1]:
        print(r['id']); break
" "$name" 2>/dev/null || true)"
  local body
  body=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":120,"proxied":false}' \
    "$type" "$name" "$content")
  if [[ -n "$id" ]]; then
    cf_api PUT "/dns_records/${id}" "$body" >/dev/null
  else
    cf_api POST "/dns_records" "$body" >/dev/null
  fi
}

ddns_update_cloudflare() {
  local v4=$1
  local v6=${2:-}
  require_cmd curl python3
  cf_upsert_record "$MAIN_DOMAIN" A "$v4"
  cf_upsert_record "$WILDCARD_DOMAIN" A "$v4"
  if [[ -n "$v6" ]]; then
    cf_upsert_record "$MAIN_DOMAIN" AAAA "$v6"
    cf_upsert_record "$WILDCARD_DOMAIN" AAAA "$v6"
  fi
}

run_ddns_update() {
  local v4 v6 provider
  v4="$(detect_public_ipv4)"
  v6="$IPV6"
  provider="$(ddns_provider)"
  case "$provider" in
    webhook)
      [[ -n "$v4" ]] || die "Could not detect public IPv4 (use --ipv4)"
      ddns_update_webhook "$v4" "$v6"
      ;;
    cloudflare)
      [[ -n "$v4" ]] || die "Could not detect public IPv4 (use --ipv4)"
      ddns_update_cloudflare "$v4" "$v6"
      ;;
    none)
      die "No DDNS provider configured (set TWS_DDNS_ENDPOINT+TWS_DDNS_TOKEN or CF_API_TOKEN+CF_ZONE_ID)"
      ;;
  esac
  log "DDNS updated for ${MAIN_DOMAIN} (provider=${provider})"
}

check_dns_name() {
  local name=$1
  if getent ahosts "$name" >/dev/null 2>&1; then
    log "DNS OK: ${name}"
    return 0
  fi
  log "DNS MISSING: ${name}"
  return 1
}

run_check() {
  local fail=0 d
  check_dns_name "$MAIN_DOMAIN" || fail=1
  while read -r d; do
    [[ -n "$d" ]] || continue
    check_dns_name "$d" || fail=1
  done < <(node_all_domains "$MAIN_DOMAIN")
  return "$fail"
}

install_systemd_timer() {
  local svc=/etc/systemd/system/tinywebstack-ddns.service
  local tmr=/etc/systemd/system/tinywebstack-ddns.timer
  local script_path="${REPO_ROOT}/scripts/vm/tinyweb-subdomain-ddns.sh"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN: would install ${svc} and ${tmr}"
    return 0
  fi
  [[ "$(id -u)" -eq 0 ]] || die "install-timer requires root"
  cat >"$svc" <<EOF
[Unit]
Description=TinyWebStack DDNS update for ${MAIN_DOMAIN}

[Service]
Type=oneshot
Environment=TWS_BASE_DOMAIN=${BASE_DOMAIN}
ExecStart=/usr/bin/bash ${script_path} --domain ${MAIN_DOMAIN}
EOF
  cat >"$tmr" <<EOF
[Unit]
Description=Periodic TinyWebStack DDNS update

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tinywebstack-ddns.timer
  log "Enabled tinywebstack-ddns.timer"
}

link_cert_to_domain() {
  local src_domain=$1
  local dest_domain=$2
  local src="/etc/yunohost/certs/${src_domain}"
  local dest="/etc/yunohost/certs/${dest_domain}"
  [[ -f "${src}/crt.pem" && -f "${src}/key.pem" ]] || die "Missing cert material under ${src}"
  mkdir -p "$dest"
  install -m 644 "${src}/crt.pem" "${dest}/crt.pem"
  install -m 600 "${src}/key.pem" "${dest}/key.pem"
}

provision_san_cert() {
  local cert_dir="/etc/yunohost/certs/${MAIN_DOMAIN}"
  local le_args=()
  if [[ -n "${TWS_LE_EMAIL:-}" ]]; then
    le_args+=(--email "$TWS_LE_EMAIL")
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    print_dry_run_summary
    return 0
  fi
  [[ "$(id -u)" -eq 0 ]] || die "provision-san-cert requires root"
  if command -v yunohost >/dev/null 2>&1; then
    if ! yunohost domain cert install "$MAIN_DOMAIN" "${le_args[@]}" -d "$WILDCARD_DOMAIN" 2>/dev/null; then
      yunohost domain cert install "$MAIN_DOMAIN" "${le_args[@]}" || \
        die "yunohost cert install failed for ${MAIN_DOMAIN}"
    fi
  elif command -v certbot >/dev/null 2>&1; then
    certbot certonly --non-interactive --agree-tos "${le_args[@]}" \
      -d "$MAIN_DOMAIN" -d "$WILDCARD_DOMAIN" || die "certbot failed"
    mkdir -p "$cert_dir"
    install -m 644 "/etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem" "${cert_dir}/crt.pem"
    install -m 600 "/etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem" "${cert_dir}/key.pem"
  else
    die "No cert tool found (yunohost or certbot)"
  fi
  local d
  while read -r d; do
    [[ -n "$d" ]] || continue
    link_cert_to_domain "$MAIN_DOMAIN" "$d"
  done < <(node_all_domains "$MAIN_DOMAIN")
  yunohost tools regen-conf --force 2>/dev/null || systemctl reload nginx 2>/dev/null || true
  log "Installed SAN/wildcard cert for ${MAIN_DOMAIN} on service domains"
}

if [[ "$DRY_RUN" == "1" && "$DO_CHECK" == "0" && "$DO_INSTALL_TIMER" == "0" && "$DO_PROVISION_SAN" == "0" ]]; then
  print_dry_run_summary
  exit 0
fi

if [[ "$DO_CHECK" == "1" ]]; then
  run_check
  exit $?
fi

if [[ "$DO_INSTALL_TIMER" == "1" ]]; then
  install_systemd_timer
fi

if [[ "$DO_PROVISION_SAN" == "1" ]]; then
  provision_san_cert
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  print_dry_run_summary
  exit 0
fi

run_ddns_update
