#!/usr/bin/env bash
# Install parent family dashboard (venv + systemd + YunoHost SSO permission).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${TW_STACK_ROOT}/lib/common.sh"
# shellcheck source=scripts/lib/domains.sh
source "${TW_STACK_ROOT}/lib/domains.sh"
# shellcheck source=scripts/lib/matrix-server.sh
source "${TW_STACK_ROOT}/lib/matrix-server.sh"
# shellcheck source=scripts/lib/synapse-admin-token.sh
source "${TW_STACK_ROOT}/lib/synapse-admin-token.sh"
# shellcheck source=scripts/lib/portal_tiles.sh
source "${TW_STACK_ROOT}/lib/portal_tiles.sh"
# shellcheck source=scripts/lib/tws_state_dir.sh
source "${TW_STACK_ROOT}/lib/tws_state_dir.sh"
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
MODULE_PERMS="${TW_STACK_ROOT}/family/permissions"
[[ -d "$MODULE_DASH" ]] || die "Missing ${MODULE_DASH}"
[[ -d "$MODULE_PERMS/tinywebstack_permissions" ]] || die "Missing ${MODULE_PERMS}"

LOC_D="$(location_domain "$MAIN_DOMAIN")"
EVENTS_D="$(events_domain "$MAIN_DOMAIN")"
NC_D="$(nextcloud_domain "$MAIN_DOMAIN")"
NC_PATH="${TWS_NEXTCLOUD_PATH:-/nextcloud}"
CALDAV_ROOT="https://${NC_D}${NC_PATH}/remote.php/dav"
MATRIX_HOST="$(matrix_public_host "$MAIN_DOMAIN")"
SYNAPSE_APP="$(yunohost app list --output-as json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
apps = data.get('apps', data)
if isinstance(apps, dict):
    for aid in sorted(apps):
        if aid == 'synapse' or 'synapse' in aid.lower():
            print(aid)
            break
    else:
        print('synapse')
else:
    print('synapse')
" || echo synapse)"
DASH_PERM="${TWS_DASHBOARD_PERM:-${SYNAPSE_APP}.family_dashboard}"
DASH_PUB_PERM="${TWS_DASHBOARD_PUB_PERM:-${SYNAPSE_APP}.family_public}"
LAB_CA="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2-utils

mkdir -p "$DASH_ROOT"
if [[ ! -x "${VENV}/bin/pip" ]]; then
  python3 -m venv "$VENV"
fi
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -e "$MODULE_FAMILY" -e "$MODULE_DASH" -e "$MODULE_PERMS"

ensure_tws_state_dir
if [[ ! -s /etc/tinywebstack/owntracks-kids.json ]]; then
  printf '{}\n' > /etc/tinywebstack/owntracks-kids.json
  chown root:www-data /etc/tinywebstack/owntracks-kids.json
  chmod 640 /etc/tinywebstack/owntracks-kids.json
fi
touch /etc/tinywebstack/owntracks-recorder.htpasswd
chown root:www-data /etc/tinywebstack/owntracks-recorder.htpasswd
chmod 640 /etc/tinywebstack/owntracks-recorder.htpasswd

CSRF_FILE="/etc/tinywebstack/dashboard.env"
CA_LINE=""
if [[ -f "$LAB_CA" ]]; then
  install -m 644 "$LAB_CA" /etc/tinywebstack/lab-ca.pem
  CA_LINE="TWS_CA_BUNDLE=/etc/tinywebstack/lab-ca.pem"
fi

write_dashboard_env() {
  local csrf=$1 invite=$2
  cat >"$CSRF_FILE" <<EOF
TWS_CSRF_SECRET=${csrf}
TWS_INVITE_SECRET=${invite}
TWS_SERVER_NAME=${MAIN_DOMAIN}
TWS_MATRIX_SERVER=${MATRIX_HOST}
TWS_POLICY_PATH=/etc/tinywebstack/family-policy.json
TWS_PENDING_INVITES_PATH=/etc/tinywebstack/pending-invites.json
TWS_PUBLIC_BASE_URL=https://${MAIN_DOMAIN}/family
TWS_FEDERATION_SYNC_CMD="sudo /usr/local/sbin/tws-family-sync-federation ${MAIN_DOMAIN}"
TWS_PARENTS_GROUP=${TWS_PARENTS_GROUP:-parents}
TWS_KIDS_GROUP=${TWS_KIDS_GROUP:-kids}
TWS_LOCATION_URL=https://${LOC_D}/
TWS_LOCATION_DOMAIN=${LOC_D}
TWS_EVENTS_URL=https://${EVENTS_D}/
TWS_EVENTS_PERMS_CMD="sudo /usr/local/sbin/tws-family-events-perms"
TWS_CALDAV_ROOT=${CALDAV_ROOT}
TWS_YUNOHOST_PRIV_HELPER="sudo /usr/local/sbin/tws-family-dashboard-privileged"
TWS_OWNTRACKS_PUBLISH_URL=https://${LOC_D}/recorder/pub
TWS_OWNTRACKS_KIDS_FILE=/etc/tinywebstack/owntracks-kids.json
TWS_OWNTRACKS_HTPASSWD=/etc/tinywebstack/owntracks-recorder.htpasswd
TWS_SYNAPSE_ADMIN_TOKEN_FILE=/etc/tinywebstack/synapse-admin-token
TWS_PERMISSIONS_DB=/etc/tinywebstack/permissions.db
TW_NODES_CONF=${TW_NODES_CONF:-/opt/tinywebstack/config/nodes.conf}
TWS_DASHBOARD_PERM=${DASH_PERM}
TWS_DASHBOARD_PUB_PERM=${DASH_PUB_PERM}
TWS_DASHBOARD_ROOT_PATH=/family
TWS_LAB_TLS_INSECURE=${TWS_LAB_TLS_INSECURE:-1}
${CA_LINE}
EOF
  chmod 640 "$CSRF_FILE"
  chown root:www-data "$CSRF_FILE"
}

if [[ ! -f "$CSRF_FILE" ]]; then
  write_dashboard_env "$(openssl rand -hex 32)" "$(openssl rand -hex 32)"
  log "Wrote ${CSRF_FILE}"
else
  grep -q '^TWS_MATRIX_SERVER=' "$CSRF_FILE" && sed -i "s|^TWS_MATRIX_SERVER=.*|TWS_MATRIX_SERVER=${MATRIX_HOST}|" "$CSRF_FILE" || printf 'TWS_MATRIX_SERVER=%s\n' "$MATRIX_HOST" >>"$CSRF_FILE"
  grep -q '^TWS_OWNTRACKS_PUBLISH_URL=' "$CSRF_FILE" || printf 'TWS_OWNTRACKS_PUBLISH_URL=https://%s/recorder/pub\n' "$LOC_D" >>"$CSRF_FILE"
  grep -q '^TWS_YUNOHOST_PRIV_HELPER=' "$CSRF_FILE" \
    && sed -i 's|^TWS_YUNOHOST_PRIV_HELPER=.*|TWS_YUNOHOST_PRIV_HELPER="sudo /usr/local/sbin/tws-family-dashboard-privileged"|' "$CSRF_FILE" \
    || printf '%s\n' 'TWS_YUNOHOST_PRIV_HELPER="sudo /usr/local/sbin/tws-family-dashboard-privileged"' >>"$CSRF_FILE"
  if grep -q '^TWS_FEDERATION_SYNC_CMD=' "$CSRF_FILE"; then
    sed -i "s|^TWS_FEDERATION_SYNC_CMD=.*|TWS_FEDERATION_SYNC_CMD=\"sudo /usr/local/sbin/tws-family-sync-federation ${MAIN_DOMAIN}\"|" "$CSRF_FILE"
  fi
  if [[ -n "$CA_LINE" ]] && ! grep -q '^TWS_CA_BUNDLE=' "$CSRF_FILE"; then
    printf '%s\n' "$CA_LINE" >>"$CSRF_FILE"
  fi
  grep -q '^TWS_DASHBOARD_PERM=' "$CSRF_FILE" \
    && sed -i "s|^TWS_DASHBOARD_PERM=.*|TWS_DASHBOARD_PERM=${DASH_PERM}|" "$CSRF_FILE" \
    || printf 'TWS_DASHBOARD_PERM=%s\n' "$DASH_PERM" >>"$CSRF_FILE"
  grep -q '^TWS_DASHBOARD_PUB_PERM=' "$CSRF_FILE" \
    && sed -i "s|^TWS_DASHBOARD_PUB_PERM=.*|TWS_DASHBOARD_PUB_PERM=${DASH_PUB_PERM}|" "$CSRF_FILE" \
    || printf 'TWS_DASHBOARD_PUB_PERM=%s\n' "$DASH_PUB_PERM" >>"$CSRF_FILE"
  grep -q '^TWS_EVENTS_URL=' "$CSRF_FILE" \
    && sed -i "s|^TWS_EVENTS_URL=.*|TWS_EVENTS_URL=https://${EVENTS_D}/|" "$CSRF_FILE" \
    || printf 'TWS_EVENTS_URL=https://%s/\n' "$EVENTS_D" >>"$CSRF_FILE"
  grep -q '^TWS_EVENTS_PERMS_CMD=' "$CSRF_FILE" \
    && sed -i 's|^TWS_EVENTS_PERMS_CMD=.*|TWS_EVENTS_PERMS_CMD="sudo /usr/local/sbin/tws-family-events-perms"|' "$CSRF_FILE" \
    || printf '%s\n' 'TWS_EVENTS_PERMS_CMD="sudo /usr/local/sbin/tws-family-events-perms"' >>"$CSRF_FILE"
  grep -q '^TWS_CALDAV_ROOT=' "$CSRF_FILE" \
    && sed -i "s|^TWS_CALDAV_ROOT=.*|TWS_CALDAV_ROOT=${CALDAV_ROOT}|" "$CSRF_FILE" \
    || printf 'TWS_CALDAV_ROOT=%s\n' "$CALDAV_ROOT" >>"$CSRF_FILE"
fi

install -d -m 775 -o root -g www-data /etc/tinywebstack
touch /etc/tinywebstack/synapse-admin-token
chown root:www-data /etc/tinywebstack/synapse-admin-token
provision_synapse_admin_token "$MAIN_DOMAIN" /etc/tinywebstack/synapse-admin-token || true
if [[ ! -s /etc/tinywebstack/synapse-admin-token ]]; then
  chmod 640 /etc/tinywebstack/synapse-admin-token
  log "Synapse admin token not provisioned — see docs/FAMILY_DASHBOARD.md"
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

install_wrapper() {
  local sbin_name=$1 script_name=$2
  cat >"/usr/local/sbin/${sbin_name}" <<EOF
#!/bin/bash
exec env TW_STACK_ROOT=/opt/tinywebstack /opt/tinywebstack/vm/${script_name}.sh "\$@"
EOF
  chmod 755 "/usr/local/sbin/${sbin_name}"
}

install_wrapper tws-family-sync-federation family-sync-federation
install_wrapper tws-family-dashboard-privileged family-dashboard-privileged
install_wrapper tws-family-events-perms family-events-perms

SUDOERS="/etc/sudoers.d/tinywebstack-family-dashboard"
TMP_SUDO="$(mktemp)"
printf '%s\n' \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-sync-federation *" \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-dashboard-privileged *" \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-events-perms" \
  >"$TMP_SUDO"
mv "$TMP_SUDO" "$SUDOERS"
chmod 440 "$SUDOERS"

PERMS_PY="${TW_STACK_ROOT}/lib/setup_family_dashboard_perms.py"
[[ -f "$PERMS_PY" ]] || die "Missing ${PERMS_PY}"
yunohost tools shell -c "
import runpy, sys
sys.argv = [
    'setup_family_dashboard_perms.py',
    '--synapse-app', '${SYNAPSE_APP}',
    '--parents-group', '${TWS_PARENTS_GROUP:-parents}',
]
runpy.run_path('${PERMS_PY}', run_name='__main__')
" || die "YunoHost permission setup failed"

yunohost user permission add "$DASH_PERM" "${TWS_PARENTS_GROUP:-parents}" || true
configure_family_home_tile "$DASH_PERM" \
  || log "WARN: could not enable Family home portal tile for ${DASH_PERM}"

NGINX_DIR="/etc/nginx/conf.d/${MAIN_DOMAIN}.d"
install -d "$NGINX_DIR"
NGINX_SNIP="${NGINX_DIR}/tinywebstack-family.conf"
TMP="$(mktemp)"
cat >"$TMP" <<EOF
# Managed by tinywebStack family dashboard
location = / {
    return 302 /family/;
}
location /.well-known/tinywebstack-family.json {
    proxy_pass http://127.0.0.1:8765/.well-known/tinywebstack-family.json;
    proxy_set_header Host \$host;
    proxy_set_header Remote-User "";
}
location /family/api/invite/verify {
    proxy_pass http://127.0.0.1:8765/api/invite/verify;
    proxy_set_header Host \$host;
    proxy_set_header Remote-User "";
}
location /family/ {
    proxy_pass http://127.0.0.1:8765/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Remote-User "";
}
EOF
mv "$TMP" "$NGINX_SNIP"
rm -f /etc/nginx/conf.d/tinywebstack-family-dashboard.conf

OWNTRACKS_PORT="$(yunohost app setting owntracks port 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$OWNTRACKS_PORT" && -f /etc/yunohost/apps/owntracks/settings.yml ]]; then
  OWNTRACKS_PORT="$(grep -E '^[[:space:]]*port:' /etc/yunohost/apps/owntracks/settings.yml | awk '{print $2}' | tr -d '\"' | head -1)"
fi
OWNTRACKS_PORT="${OWNTRACKS_PORT:-8085}"
NGINX_OT_DIR="/etc/nginx/conf.d/${LOC_D}.d"
install -d "$NGINX_OT_DIR"
NGINX_OT_SNIP="${NGINX_OT_DIR}/tinywebstack-owntracks-pub.conf"
TMP_OT="$(mktemp)"
cat >"$TMP_OT" <<EOF
# Managed by tinywebStack — basic-auth publish for family kids (survives owntracks_ynh upgrades)
location /recorder/pub {
    auth_basic "OwnTracks family";
    auth_basic_user_file /etc/tinywebstack/owntracks-recorder.htpasswd;
    proxy_pass http://127.0.0.1:${OWNTRACKS_PORT}/pub;
    proxy_set_header Host \$host;
    set \$tws_ot_user \$remote_user;
    proxy_set_header X-Limit-U \$tws_ot_user;
}
EOF
mv "$TMP_OT" "$NGINX_OT_SNIP"

yunohost service reload nginx

log "Family dashboard listening on 127.0.0.1:8765 (public https://${MAIN_DOMAIN}/family/)"
