#!/usr/bin/env bash
# Install ntfy (UnifiedPush / Matrix gateway) and Sygnal (APNs/optional FCM) on the family box.
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_script_dir}/../lib/common.sh" ]]; then
  _tws_lib_dir="$(cd "${_script_dir}/../lib" && pwd)"
elif [[ -n "${TW_STACK_ROOT:-}" && -f "${TW_STACK_ROOT}/lib/common.sh" ]]; then
  _tws_lib_dir="${TW_STACK_ROOT}/lib"
else
  echo "Cannot locate scripts/lib/common.sh" >&2
  exit 1
fi
if [[ -z "${TW_STACK_ROOT:-}" ]] && [[ -f "${_tws_lib_dir}/tw_stack_root.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_tws_lib_dir}/tw_stack_root.sh"
  TW_STACK_ROOT="$(tw_stack_root_from_script_dir "$_script_dir" || true)"
fi
: "${TW_STACK_ROOT:=$(cd "${_script_dir}/.." && pwd)}"
# shellcheck source=/dev/null
source "${_tws_lib_dir}/common.sh"
# shellcheck source=/dev/null
source "${_tws_lib_dir}/domains.sh"
# shellcheck source=/dev/null
source "${_tws_lib_dir}/tws_state_dir.sh"
load_config

usage() {
  echo "Usage: install-push.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -ge 1 ]] || usage
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]] && ! dry_run_is_active && [[ "${TWS_ALLOW_NONROOT:-0}" != "1" ]]; then
  echo "Run as root on the YunoHost VM (or DRY_RUN=1)" >&2
  exit 1
fi

TWS_PUSH_ENABLE="${TWS_PUSH_ENABLE:-1}"
if [[ "$TWS_PUSH_ENABLE" == "0" ]]; then
  log "TWS_PUSH_ENABLE=0 — skipping push install"
  exit 0
fi

PUSH_D="$(push_domain "$MAIN_DOMAIN")"
TWS_ETC_DIR="${TWS_ETC_DIR:-/etc/tinywebstack}"
NTFY_PORT="${TWS_NTFY_PORT:-8090}"
SYGNAL_PORT="${TWS_SYGNAL_PORT:-5000}"
CSRF_FILE="${TWS_DASHBOARD_ENV_FILE:-${TWS_ETC_DIR}/dashboard.env}"
APNS_BUNDLE="${TWS_APNS_BUNDLE_ID:-win.tinyweb.tinyweb}"
APNS_KEY_ID="${TWS_APNS_KEY_ID:-}"
APNS_TEAM_ID="${TWS_APNS_TEAM_ID:-}"
APNS_ENV="${TWS_APNS_ENV:-sandbox}"
APNS_KEY_PATH="${TWS_APNS_KEY_PATH:-${TWS_ETC_DIR}/secrets/apns/AuthKey.p8}"
VERSIONS_FILE="${_script_dir}/push-versions.env"
if [[ ! -f "$VERSIONS_FILE" ]]; then
  VERSIONS_FILE="${TW_STACK_ROOT}/config/push-versions.env"
fi
[[ -f "$VERSIONS_FILE" ]] || die "Missing push-versions.env (scripts/vm/ or config/)"
# shellcheck source=/dev/null
source "$VERSIONS_FILE"
NTFY_SHA_amd64="${TWS_NTFY_SHA256_amd64:?missing TWS_NTFY_SHA256_amd64}"
NTFY_SHA_arm64="${TWS_NTFY_SHA256_arm64:?missing TWS_NTFY_SHA256_arm64}"

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) die "Unsupported arch for ntfy: $(uname -m)" ;;
  esac
}

install_ntfy_binary() {
  local arch ver tarball url expected
  arch="$(host_arch)"
  ver="${TWS_NTFY_VERSION#v}"
  tarball="ntfy_${ver}_linux_${arch}.tar.gz"
  url="https://github.com/binwiederhier/ntfy/releases/download/${TWS_NTFY_VERSION}/${tarball}"
  case "$arch" in
    amd64) expected="$NTFY_SHA_amd64" ;;
    arm64) expected="$NTFY_SHA_arm64" ;;
    *) die "No checksum for arch ${arch}" ;;
  esac
  [[ -n "$expected" ]] || die "No checksum for arch ${arch} in ${VERSIONS_FILE}"

  local cache_dir="${TWS_ETC_DIR}/cache"
  local dl="${cache_dir}/${tarball}"
  if dry_run_is_active; then
    log "DRY_RUN: download ${url} -> ${dl} (sha256 ${expected})"
    log "DRY_RUN: install ntfy to /usr/local/bin/ntfy"
    return 0
  fi
  mkdir -p "$cache_dir"
  if [[ ! -f "$dl" ]]; then
    curl -fsSL -o "$dl" "$url"
  fi
  echo "${expected}  ${dl}" | sha256sum -c -
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$dl" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name ntfy -perm -u+x | head -1)"
  [[ -n "$bin" ]] || die "ntfy binary not found in ${tarball}"
  install -m 755 "$bin" /usr/local/bin/ntfy
  rm -rf "$tmp"
  log "Installed ntfy ${TWS_NTFY_VERSION} to /usr/local/bin/ntfy"
}

write_ntfy_config() {
  local cfg="${TWS_ETC_DIR}/ntfy/server.yml"
  if dry_run_is_active; then
    log "DRY_RUN: write ${cfg}"
    return 0
  fi
  mkdir -p "${TWS_ETC_DIR}/ntfy"
  cat >"$cfg" <<EOF
# Managed by tinywebStack install-push.sh
base-url: "https://${PUSH_D}"
listen-http: "127.0.0.1:${NTFY_PORT}"
behind-proxy: true
# Subscribers need read on unguessable topics; Matrix notify path is always allowed by ntfy.
auth-default-access: read-only
enable-login: false
attachment-cache-dir: ""
upstream-base-url: ""
EOF
  chmod 640 "$cfg"
}

install_ntfy_unit() {
  local unit=/etc/systemd/system/tinywebstack-ntfy.service
  if dry_run_is_active; then
    log "DRY_RUN: write ${unit} and enable tinywebstack-ntfy"
    return 0
  fi
  cat >"$unit" <<EOF
[Unit]
Description=tinywebStack ntfy (Matrix push gateway / UnifiedPush)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ntfy serve --config ${TWS_ETC_DIR}/ntfy/server.yml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable tinywebstack-ntfy.service
  systemctl restart tinywebstack-ntfy.service
}

ensure_push_domain() {
  if dry_run_is_active; then
    log "DRY_RUN: yunohost domain add ${PUSH_D} (if missing)"
    return 0
  fi
  if ! yunohost domain list 2>/dev/null | grep -qw "$PUSH_D"; then
    yunohost domain add "$PUSH_D"
  fi
  if [[ -f "${TW_STACK_ROOT}/lab-certs/${PUSH_D}/fullchain.pem" ]]; then
    "${TW_STACK_ROOT}/vm/yunohost-lab-tls.sh" "$PUSH_D" || true
  elif [[ "${TWS_MODE:-lab}" == "lab" ]]; then
    yunohost domain cert install "$PUSH_D" --self-signed 2>/dev/null || \
      yunohost domain cert install "$PUSH_D" --self-signed || true
  fi
}

write_push_nginx() {
  local dir="/etc/nginx/conf.d/${PUSH_D}.d"
  local snip="${dir}/tinywebstack-push.conf"
  if dry_run_is_active; then
    log "DRY_RUN: write ${snip}"
    return 0
  fi
  mkdir -p "$dir"
  cat >"$snip" <<EOF
# Managed by tinywebStack install-push.sh
location /sygnal/ {
    proxy_pass http://127.0.0.1:${SYGNAL_PORT}/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
location / {
    proxy_pass http://127.0.0.1:${NTFY_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s;
}
EOF
  yunohost service reload nginx || systemctl reload nginx
}

write_sygnal_config() {
  local cfg="${TWS_ETC_DIR}/sygnal.yaml"
  local apns_enabled=0
  if [[ -f "$APNS_KEY_PATH" && -n "$APNS_KEY_ID" && -n "$APNS_TEAM_ID" ]]; then
    apns_enabled=1
  fi
  if dry_run_is_active; then
    log "DRY_RUN: write ${cfg} (APNs enabled=${apns_enabled})"
    return 0
  fi
  mkdir -p "$(dirname "$APNS_KEY_PATH")" "${TWS_ETC_DIR}/secrets/fcm"
  local ios_app="${APNS_BUNDLE}.ios"
  if [[ "$apns_enabled" -eq 1 ]]; then
    cat >"$cfg" <<EOF
# Managed by tinywebStack install-push.sh
log:
  setup:
    version: 1
    formatters:
      precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: precise
    root:
      level: INFO
      handlers: [console]
http:
  bind_addresses: ['127.0.0.1']
  port: ${SYGNAL_PORT}
apps:
  ${ios_app}:
    type: apns
    keyfile: ${APNS_KEY_PATH}
    key_id: ${APNS_KEY_ID}
    team_id: ${APNS_TEAM_ID}
    topic: ${APNS_BUNDLE}
    platform: ${APNS_ENV}
    default_payload:
      aps:
        alert:
          title: TinyWeb
          body: New message
        mutable-content: 1
EOF
    log "Sygnal APNs enabled for ${ios_app} (${APNS_ENV})"
  else
    cat >"$cfg" <<EOF
# Managed by tinywebStack install-push.sh — APNs disabled until AuthKey.p8 is installed.
log:
  setup:
    version: 1
    formatters:
      precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: precise
    root:
      level: INFO
      handlers: [console]
http:
  bind_addresses: ['127.0.0.1']
  port: ${SYGNAL_PORT}
apps: {}
EOF
    log "Sygnal installed; APNs disabled (place ${APNS_KEY_PATH} and set TWS_APNS_KEY_ID / TWS_APNS_TEAM_ID, then re-run install-push.sh)"
  fi
  chmod 640 "$cfg"
}

install_sygnal_venv() {
  local root="/opt/tinywebstack/push/sygnal"
  local venv="${root}/venv"
  if dry_run_is_active; then
    log "DRY_RUN: python venv ${venv} and pip install sygnal ${TWS_SYGNAL_GIT_REF}"
    return 0
  fi
  mkdir -p "$root"
  if [[ ! -x "${venv}/bin/pip" ]]; then
    python3 -m venv "$venv"
  fi
  "${venv}/bin/pip" install -q --upgrade pip
  "${venv}/bin/pip" install -q "git+https://github.com/element-hq/sygnal.git@${TWS_SYGNAL_GIT_REF}"
}

install_sygnal_unit() {
  local unit=/etc/systemd/system/tinywebstack-sygnal.service
  local venv="/opt/tinywebstack/push/sygnal/venv"
  if dry_run_is_active; then
    log "DRY_RUN: write ${unit}"
    return 0
  fi
  cat >"$unit" <<EOF
[Unit]
Description=tinywebStack Sygnal (Matrix push gateway for APNs/FCM)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/tinywebstack/push/sygnal
ExecStart=${venv}/bin/sygnal --config ${TWS_ETC_DIR}/sygnal.yaml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable tinywebstack-sygnal.service
  systemctl restart tinywebstack-sygnal.service
}

write_synapse_push_snippet() {
  local conf_d="${TWS_SYNAPSE_CONF_D:-/etc/matrix-synapse/conf.d}"
  local snip="${conf_d}/tinywebstack-push.yaml"
  local tpl="${TW_STACK_ROOT}/templates/synapse/tinywebstack-push.yaml.example"
  if dry_run_is_active; then
    log "DRY_RUN: install ${snip} from template"
    return 0
  fi
  mkdir -p "$conf_d"
  if [[ -f "$tpl" ]]; then
    install -m 644 "$tpl" "$snip"
  else
    cat >"$snip" <<'EOF'
ip_range_whitelist:
  - "127.0.0.1"
EOF
  fi
  if systemctl is-active --quiet synapse 2>/dev/null; then
    systemctl restart synapse || systemctl restart matrix-synapse || true
  fi
}

update_dashboard_env() {
  if [[ ! -f "$CSRF_FILE" ]]; then
    log "WARN: ${CSRF_FILE} missing — run install-family-dashboard.sh first"
    return 0
  fi
  if dry_run_is_active; then
    log "DRY_RUN: update push keys in ${CSRF_FILE}"
    return 0
  fi
  grep -q '^TWS_PUSH_ENABLE=' "$CSRF_FILE" \
    && sed -i "s|^TWS_PUSH_ENABLE=.*|TWS_PUSH_ENABLE=1|" "$CSRF_FILE" \
    || printf 'TWS_PUSH_ENABLE=1\n' >>"$CSRF_FILE"
  grep -q '^TWS_PUSH_PUBLIC_HOST=' "$CSRF_FILE" \
    && sed -i "s|^TWS_PUSH_PUBLIC_HOST=.*|TWS_PUSH_PUBLIC_HOST=${PUSH_D}|" "$CSRF_FILE" \
    || printf 'TWS_PUSH_PUBLIC_HOST=%s\n' "$PUSH_D" >>"$CSRF_FILE"
  grep -q '^TWS_PUSH_PUBLIC_BASE_URL=' "$CSRF_FILE" \
    && sed -i "s|^TWS_PUSH_PUBLIC_BASE_URL=.*|TWS_PUSH_PUBLIC_BASE_URL=https://${MAIN_DOMAIN}/push|" "$CSRF_FILE" \
    || printf 'TWS_PUSH_PUBLIC_BASE_URL=https://%s/push\n' "$MAIN_DOMAIN" >>"$CSRF_FILE"
  grep -q '^TWS_NTFY_PORT=' "$CSRF_FILE" \
    && sed -i "s|^TWS_NTFY_PORT=.*|TWS_NTFY_PORT=${NTFY_PORT}|" "$CSRF_FILE" \
    || printf 'TWS_NTFY_PORT=%s\n' "$NTFY_PORT" >>"$CSRF_FILE"
  grep -q '^TWS_SYGNAL_PORT=' "$CSRF_FILE" \
    && sed -i "s|^TWS_SYGNAL_PORT=.*|TWS_SYGNAL_PORT=${SYGNAL_PORT}|" "$CSRF_FILE" \
    || printf 'TWS_SYGNAL_PORT=%s\n' "$SYGNAL_PORT" >>"$CSRF_FILE"
  grep -q '^TWS_APNS_BUNDLE_ID=' "$CSRF_FILE" \
    && sed -i "s|^TWS_APNS_BUNDLE_ID=.*|TWS_APNS_BUNDLE_ID=${APNS_BUNDLE}|" "$CSRF_FILE" \
    || printf 'TWS_APNS_BUNDLE_ID=%s\n' "$APNS_BUNDLE" >>"$CSRF_FILE"
}

install_ntfy_binary
write_ntfy_config
install_ntfy_unit
ensure_push_domain
write_push_nginx
install_sygnal_venv
write_sygnal_config
install_sygnal_unit
write_synapse_push_snippet
update_dashboard_env

log "Push stack ready: ntfy 127.0.0.1:${NTFY_PORT}, Sygnal 127.0.0.1:${SYGNAL_PORT}, public https://${PUSH_D}/"
