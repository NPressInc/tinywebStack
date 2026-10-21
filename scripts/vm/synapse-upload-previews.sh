#!/usr/bin/env bash
# Synapse media upload limit + disabled URL previews; nginx body size for Matrix media.
#
# Usage: synapse-upload-previews.sh MAIN_DOMAIN
# DRY_RUN=1 prints rendered Synapse YAML and nginx snippets (no root, no writes).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  cat <<'EOF'
Usage: synapse-upload-previews.sh MAIN_DOMAIN

Sets max_upload_size 200M, url_preview_enabled false (conf.d + YunoHost app setting),
and client_max_body_size 200M on the Matrix vhost (and main domain when present).
DRY_RUN=1 prints rendered config to stdout.
EOF
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1

CONF_D="${TWS_SYNAPSE_CONF_D:-/etc/matrix-synapse/conf.d}"
SNIPPET="${CONF_D}/tinywebstack-media.yaml"
TPL="${TW_STACK_ROOT}/templates/synapse/tinywebstack-media.yaml.example"
MAX_UPLOAD="${TWS_SYNAPSE_MAX_UPLOAD_SIZE:-200M}"
NGINX_BODY="${TWS_NGINX_MATRIX_MAX_BODY:-200M}"
MATRIX_D="$(matrix_domain "$MAIN_DOMAIN")"

render_synapse_snippet() {
  if [[ -f "$TPL" ]]; then
    sed "s/^max_upload_size:.*/max_upload_size: ${MAX_UPLOAD}/" "$TPL"
  else
    cat <<EOF
# Managed by tinywebStack synapse-upload-previews.sh
max_upload_size: ${MAX_UPLOAD}
url_preview_enabled: false
EOF
  fi
}

render_nginx_snippet() {
  cat <<EOF
# Managed by tinywebStack synapse-upload-previews.sh
client_max_body_size ${NGINX_BODY};
EOF
}

if dry_run_is_active; then
  log "DRY_RUN: Synapse media snippet for ${MAIN_DOMAIN}"
  render_synapse_snippet
  echo "---"
  log "DRY_RUN: nginx snippet for ${MATRIX_D} (and ${MAIN_DOMAIN} when installed)"
  render_nginx_snippet
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

apply_yunohost_max_upload() {
  if ! command -v yunohost >/dev/null 2>&1; then
    return 0
  fi
  if ! yunohost app list 2>/dev/null | grep -qw synapse; then
    return 0
  fi
  local current=""
  current="$(yunohost app setting synapse max_upload_size 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$current" ]]; then
    yunohost app setting synapse max_upload_size -v "$MAX_UPLOAD" 2>/dev/null \
      || log "WARN: yunohost app setting synapse max_upload_size failed (conf.d still applies)"
    return 0
  fi
  if [[ "${current,,}" != "${MAX_UPLOAD,,}" ]]; then
    yunohost app setting synapse max_upload_size -v "$MAX_UPLOAD" 2>/dev/null \
      || log "WARN: yunohost app setting synapse max_upload_size failed (conf.d still applies)"
  fi
}

synapse_snippet_changed=0
[[ -d "$CONF_D" ]] || mkdir -p "$CONF_D"
TMP="$(mktemp)"
render_synapse_snippet >"$TMP"
if [[ -f "$SNIPPET" ]] && cmp -s "$TMP" "$SNIPPET"; then
  rm -f "$TMP"
  log "Synapse media snippet unchanged"
else
  mv "$TMP" "$SNIPPET"
  synapse_snippet_changed=1
  if getent group synapse >/dev/null 2>&1; then
    chown root:synapse "$SNIPPET"
    chmod 640 "$SNIPPET"
  elif getent group matrix-synapse >/dev/null 2>&1; then
    chown root:matrix-synapse "$SNIPPET"
    chmod 640 "$SNIPPET"
  else
    chmod 644 "$SNIPPET"
  fi
  log "Wrote ${SNIPPET}"
fi

apply_yunohost_max_upload

nginx_changed=0
install_nginx_snippet_for_domain() {
  local domain=$1
  if ! yunohost domain list 2>/dev/null | grep -qw "$domain"; then
    return 0
  fi
  local dir="/etc/nginx/conf.d/${domain}.d"
  local snip="${dir}/tinywebstack-synapse-media.conf"
  mkdir -p "$dir"
  local tmp_ng
  tmp_ng="$(mktemp)"
  render_nginx_snippet >"$tmp_ng"
  if [[ -f "$snip" ]] && cmp -s "$tmp_ng" "$snip"; then
    rm -f "$tmp_ng"
    return 0
  fi
  mv "$tmp_ng" "$snip"
  nginx_changed=1
  log "Wrote ${snip}"
}

install_nginx_snippet_for_domain "$MATRIX_D"
install_nginx_snippet_for_domain "$MAIN_DOMAIN"

restart_synapse() {
  if systemctl list-unit-files synapse.service >/dev/null 2>&1; then
    systemctl restart synapse
  elif systemctl list-unit-files matrix-synapse.service >/dev/null 2>&1; then
    systemctl restart matrix-synapse
  else
    systemctl restart synapse 2>/dev/null || systemctl restart matrix-synapse
  fi
}

reload_nginx() {
  if ! nginx -t 2>/dev/null; then
    die "nginx -t failed after writing tinywebstack-synapse-media.conf"
  fi
  if command -v yunohost >/dev/null 2>&1; then
    yunohost service reload nginx
  else
    systemctl reload nginx
  fi
}

if [[ "$synapse_snippet_changed" -eq 1 ]]; then
  restart_synapse
fi
if [[ "$nginx_changed" -eq 1 ]]; then
  reload_nginx
fi

echo "Synapse upload/previews config applied for ${MAIN_DOMAIN} (matrix host ${MATRIX_D})"
