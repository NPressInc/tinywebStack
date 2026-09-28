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

LOC_D="$(location_domain "$MAIN_DOMAIN")"
MATRIX_HOST="$(matrix_public_host "$MAIN_DOMAIN")"
DASH_PERM="${TWS_DASHBOARD_PERM:-core_family.main}"
DASH_PUB_PERM="${TWS_DASHBOARD_PUB_PERM:-core_family.public}"
LAB_CA="${TW_STACK_ROOT}/lab-certs/lab-ca.crt.pem"

mkdir -p "$DASH_ROOT"
if [[ ! -x "${VENV}/bin/pip" ]]; then
  python3 -m venv "$VENV"
fi
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -e "$MODULE_FAMILY" -e "$MODULE_DASH"

install -d -m 775 -o root -g www-data /etc/tinywebstack
printf '{}\n' > /etc/tinywebstack/owntracks-kids.json
chown root:www-data /etc/tinywebstack/owntracks-kids.json
chmod 640 /etc/tinywebstack/owntracks-kids.json
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
TWS_FEDERATION_SYNC_CMD=sudo /usr/local/sbin/tws-family-sync-federation ${MAIN_DOMAIN}
TWS_PARENTS_GROUP=${TWS_PARENTS_GROUP:-parents}
TWS_KIDS_GROUP=${TWS_KIDS_GROUP:-kids}
TWS_LOCATION_URL=https://${LOC_D}/
TWS_LOCATION_DOMAIN=${LOC_D}
TWS_YUNOHOST_PRIV_HELPER=sudo /usr/local/sbin/tws-family-dashboard-privileged
TWS_OWNTRACKS_PUBLISH_URL=https://${LOC_D}/recorder/pub
TWS_OWNTRACKS_KIDS_FILE=/etc/tinywebstack/owntracks-kids.json
TWS_OWNTRACKS_HTPASSWD=/etc/tinywebstack/owntracks-recorder.htpasswd
TWS_SYNAPSE_ADMIN_TOKEN_FILE=/etc/tinywebstack/synapse-admin-token
TWS_DASHBOARD_PERM=${DASH_PERM}
TWS_DASHBOARD_PUB_PERM=${DASH_PUB_PERM}
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
  grep -q '^TWS_YUNOHOST_PRIV_HELPER=' "$CSRF_FILE" || printf 'TWS_YUNOHOST_PRIV_HELPER=sudo /usr/local/sbin/tws-family-dashboard-privileged\n' >>"$CSRF_FILE"
  if [[ -n "$CA_LINE" ]] && ! grep -q '^TWS_CA_BUNDLE=' "$CSRF_FILE"; then
    printf '%s\n' "$CA_LINE" >>"$CSRF_FILE"
  fi
fi

if [[ ! -f /etc/tinywebstack/synapse-admin-token ]]; then
  install -m 640 /dev/null /etc/tinywebstack/synapse-admin-token
  chown root:www-data /etc/tinywebstack/synapse-admin-token
  log "Created empty /etc/tinywebstack/synapse-admin-token (see docs/FAMILY_DASHBOARD.md)"
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

SUDOERS="/etc/sudoers.d/tinywebstack-family-dashboard"
TMP_SUDO="$(mktemp)"
printf '%s\n' \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-sync-federation *" \
  "www-data ALL=(root) NOPASSWD: /usr/local/sbin/tws-family-dashboard-privileged *" \
  >"$TMP_SUDO"
mv "$TMP_SUDO" "$SUDOERS"
chmod 440 "$SUDOERS"

yunohost tools shell -c "
from yunohost.utils.permissions import permission_create, permission_url_add
for perm, url, auth in [
    ('${DASH_PERM}', '/family', True),
    ('${DASH_PUB_PERM}', '/family/api/invite/verify', False),
]:
    try:
        permission_create(perm, {'auth_header': auth, 'show_tile': False})
    except Exception:
        pass
    try:
        permission_url_add(perm, 'main', {'url': url, 'auth_header': auth})
    except Exception:
        pass
permission_url_add('${DASH_PUB_PERM}', 'wellknown', {'url': '/.well-known/tinywebstack-family.json', 'auth_header': False})
" || die "YunoHost permission setup failed"

yunohost user permission add "$DASH_PERM" "${TWS_PARENTS_GROUP:-parents}"
yunohost user permission add "$DASH_PUB_PERM" visitors || true

NGINX_DIR="/etc/nginx/conf.d/${MAIN_DOMAIN}.d"
install -d "$NGINX_DIR"
NGINX_SNIP="${NGINX_DIR}/tinywebstack-family.conf"
TMP="$(mktemp)"
cat >"$TMP" <<EOF
# Managed by tinywebStack family dashboard
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
location /recorder/pub {
    auth_basic "OwnTracks";
    auth_basic_user_file /etc/tinywebstack/owntracks-recorder.htpasswd;
    proxy_pass http://127.0.0.1:8085/pub;
    proxy_set_header Host \$host;
}
EOF
mv "$TMP" "$NGINX_SNIP"
rm -f /etc/nginx/conf.d/tinywebstack-family-dashboard.conf
yunohost service reload nginx

log "Family dashboard listening on 127.0.0.1:8765 (public https://${MAIN_DOMAIN}/family/)"
