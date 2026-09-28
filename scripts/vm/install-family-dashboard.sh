#!/usr/bin/env bash
# Install parent family dashboard (venv + systemd + YunoHost SSO permission).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
load_config

usage() {
  echo "Usage: install-family-dashboard.sh MAIN_DOMAIN"
  exit 1
}

[[ $# -eq 1 ]] || usage
MAIN_DOMAIN=$1

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

DASH_ROOT="/opt/tinywebstack-family-dashboard"
VENV="${DASH_ROOT}/venv"
MODULE_FAMILY="${TW_STACK_ROOT}/family/synapse_module"
MODULE_DASH="${TW_STACK_ROOT}/family/dashboard"
[[ -d "$MODULE_DASH" ]] || die "Missing ${MODULE_DASH}"

mkdir -p "$DASH_ROOT"
if [[ ! -x "${VENV}/bin/pip" ]]; then
  python3 -m venv "$VENV"
fi
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -e "$MODULE_FAMILY" -e "$MODULE_DASH"

CSRF_FILE="/etc/tinywebstack/dashboard.env"
if [[ ! -f "$CSRF_FILE" ]]; then
  CSRF="$(openssl rand -hex 32)"
  install -m 600 /dev/null "$CSRF_FILE"
  cat >"$CSRF_FILE" <<EOF
TWS_CSRF_SECRET=${CSRF}
TWS_SERVER_NAME=${MAIN_DOMAIN}
TWS_POLICY_PATH=/etc/tinywebstack/family-policy.json
TWS_PARENTS_GROUP=${TWS_PARENTS_GROUP:-parents}
TWS_KIDS_GROUP=${TWS_KIDS_GROUP:-kids}
TWS_LOCATION_URL=https://$(location_domain "$MAIN_DOMAIN")/
EOF
  log "Wrote ${CSRF_FILE}"
fi

UNIT="/etc/systemd/system/tinywebstack-family-dashboard.service"
TMP="$(mktemp)"
cat >"$TMP" <<EOF
[Unit]
Description=tinywebStack family parent dashboard
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=${DASH_ROOT}
EnvironmentFile=${CSRF_FILE}
ExecStart=${VENV}/bin/uvicorn tinywebstack_dashboard.app:app --host 127.0.0.1 --port 8765
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
if [[ ! -f "$UNIT" ]] || ! cmp -s "$TMP" "$UNIT"; then
  mv "$TMP" "$UNIT"
  systemctl daemon-reload
  systemctl enable tinywebstack-family-dashboard.service
else
  rm -f "$TMP"
fi
systemctl restart tinywebstack-family-dashboard.service

# YunoHost permission + nginx snippet (SSOwat on main domain /family/)
PERM="family-dashboard.main"
if ! yunohost user permission list 2>/dev/null | grep -qw "$PERM"; then
  yunohost user permission create "$PERM" \
    --label="Family dashboard" \
    --url="/family/" \
    --show_tile=true 2>/dev/null || log "Could not create permission ${PERM} (may already exist)"
fi
yunohost user permission update "$PERM" --add "${TWS_PARENTS_GROUP:-parents}" 2>/dev/null || true

NGINX_SNIP="/etc/nginx/conf.d/tinywebstack-family-dashboard.conf"
TMP="$(mktemp)"
cat >"$TMP" <<'EOF'
# Managed by tinywebStack — SSOwat protects /family/ via YunoHost permission family-dashboard.main
location /family/ {
    proxy_pass http://127.0.0.1:8765/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
EOF
if [[ ! -f "$NGINX_SNIP" ]] || ! cmp -s "$TMP" "$NGINX_SNIP"; then
  mv "$TMP" "$NGINX_SNIP"
  yunohost service reload nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true
else
  rm -f "$TMP"
fi

log "Family dashboard listening on 127.0.0.1:8765 (public https://${MAIN_DOMAIN}/family/)"
