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
  INVITE_SECRET="$(openssl rand -hex 32)"
  MATRIX_D="$(matrix_domain "$MAIN_DOMAIN")"
  cat >"$CSRF_FILE" <<EOF
TWS_CSRF_SECRET=${CSRF}
TWS_INVITE_SECRET=${INVITE_SECRET}
TWS_SERVER_NAME=${MAIN_DOMAIN}
TWS_MATRIX_SERVER=${MATRIX_D}
TWS_POLICY_PATH=/etc/tinywebstack/family-policy.json
TWS_PENDING_INVITES_PATH=/etc/tinywebstack/pending-invites.json
TWS_PUBLIC_BASE_URL=https://${MAIN_DOMAIN}/family
TWS_FEDERATION_SYNC_CMD=sudo /usr/local/sbin/tws-family-sync-federation ${MAIN_DOMAIN}
TWS_PARENTS_GROUP=${TWS_PARENTS_GROUP:-parents}
TWS_KIDS_GROUP=${TWS_KIDS_GROUP:-kids}
TWS_LOCATION_URL=https://$(location_domain "$MAIN_DOMAIN")/
TWS_LOCATION_DOMAIN=$(location_domain "$MAIN_DOMAIN")
TWS_YUNOHOST_PRIV_HELPER=sudo /usr/local/sbin/tws-family-dashboard-privileged
TWS_OWNTRACKS_PUBLISH_URL=https://$(location_domain "$MAIN_DOMAIN")/api/
TWS_OWNTRACKS_KIDS_FILE=/etc/tinywebstack/owntracks-kids.json
TWS_SYNAPSE_ADMIN_TOKEN_FILE=/etc/tinywebstack/synapse-admin-token
TWS_LAB_TLS_INSECURE=1
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

install -m 755 "${TW_STACK_ROOT}/vm/family-sync-federation.sh" /usr/local/sbin/tws-family-sync-federation
install -m 755 "${TW_STACK_ROOT}/vm/family-dashboard-privileged.sh" /usr/local/sbin/tws-family-dashboard-privileged
SUDOERS="/etc/sudoers.d/tinywebstack-family-dashboard"
TMP_SUDO="$(mktemp)"
printf '%s\n' \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-sync-federation *" \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-dashboard-privileged *" \
  >"$TMP_SUDO"
if [[ ! -f "$SUDOERS" ]] || ! cmp -s "$TMP_SUDO" "$SUDOERS"; then
  mv "$TMP_SUDO" "$SUDOERS"
  chmod 440 "$SUDOERS"
else
  rm -f "$TMP_SUDO"
fi

LOC_D="$(location_domain "$MAIN_DOMAIN")"
MATRIX_D="$(matrix_domain "$MAIN_DOMAIN")"
touch /etc/tinywebstack/owntracks-kids.json
chown root:www-data /etc/tinywebstack/owntracks-kids.json
chmod 640 /etc/tinywebstack/owntracks-kids.json
if [[ ! -f /etc/tinywebstack/synapse-admin-token ]]; then
  install -m 640 /dev/null /etc/tinywebstack/synapse-admin-token
  chown root:www-data /etc/tinywebstack/synapse-admin-token
  log "Created empty /etc/tinywebstack/synapse-admin-token (see docs/FAMILY_DASHBOARD.md)"
fi

# Append dashboard env keys when upgrading an existing install.
append_env() {
  local key=$1 val=$2
  if ! grep -q "^${key}=" "$CSRF_FILE" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$val" >>"$CSRF_FILE"
  fi
}
append_env TWS_YUNOHOST_PRIV_HELPER "sudo /usr/local/sbin/tws-family-dashboard-privileged"
append_env TWS_LOCATION_DOMAIN "$LOC_D"
append_env TWS_OWNTRACKS_PUBLISH_URL "https://${LOC_D}/api/"
append_env TWS_OWNTRACKS_KIDS_FILE "/etc/tinywebstack/owntracks-kids.json"
append_env TWS_SYNAPSE_ADMIN_TOKEN_FILE "/etc/tinywebstack/synapse-admin-token"
append_env TWS_LAB_TLS_INSECURE "${TWS_LAB_TLS_INSECURE:-1}"

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
location /.well-known/tinywebstack-family.json {
    proxy_pass http://127.0.0.1:8765/.well-known/tinywebstack-family.json;
    proxy_set_header Host $host;
}
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
