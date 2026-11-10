#!/usr/bin/env bash
# Hook for TinyWeb-operated APNs/FCM credentials (Sygnal).
#
# install-push.sh calls this. A parent does not upload a key file.
# Re-run after operator secrets are in place, then re-run install-push.sh so
# the Sygnal unit leaves the refusing stub. See docs/PUSH.md.
#
# Exit 0: credentials configured (and Sygnal yaml written with --write-sygnal).
# Exit 2: operator credentials missing or unusable. Delivery is not configured.
# Never prints key material.
set -euo pipefail
set +x

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_script_dir}/../lib/common.sh" ]]; then
  _tws_lib_dir="$(cd "${_script_dir}/../lib" && pwd)"
elif [[ -n "${TW_STACK_ROOT:-}" && -f "${TW_STACK_ROOT}/lib/common.sh" ]]; then
  _tws_lib_dir="${TW_STACK_ROOT}/lib"
else
  echo "Cannot locate scripts/lib/common.sh" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${_tws_lib_dir}/common.sh"

usage() {
  cat <<'EOF'
Usage: configure-push-credentials.sh [--write-sygnal]

Loads TinyWeb-operated APNs/FCM credentials (default source: tinyweb) and
writes /etc/tinywebstack/push/credential-status.json. With --write-sygnal,
also writes sygnal.yaml. Missing operator keys exit 2 and do not report
delivery success.

Environment:
  TWS_PUSH_CREDENTIAL_SOURCE   tinyweb (default) or override (lab/dev only)
  TWS_ETC_DIR                  default /etc/tinywebstack
  TWS_SYGNAL_PORT              default 5000
  TWS_APNS_KEY / _B64 / _FILE, TWS_APNS_KEY_ID, TWS_APNS_TEAM_ID
  TWS_FCM_SERVICE_ACCOUNT_JSON / _B64 / _FILE
  Operator file: $TWS_ETC_DIR/secrets/push/operator.env (mode 600)

Does not print secret values.
EOF
  exit 1
}

WRITE_SYGNAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --write-sygnal) WRITE_SYGNAL=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if dry_run_is_active; then
  log "DRY_RUN: configure TinyWeb push credentials (source=${TWS_PUSH_CREDENTIAL_SOURCE:-tinyweb}) under ${TWS_ETC_DIR:-/etc/tinywebstack}"
  exit 0
fi

py="${_tws_lib_dir}/push_operator_config.py"
[[ -f "$py" ]] || die "Missing ${py}"

cmd=(python3 "$py")
if [[ "$WRITE_SYGNAL" -eq 1 ]]; then
  cmd+=(apply)
else
  cmd+=(check)
fi
cmd+=(--etc-dir "${TWS_ETC_DIR:-/etc/tinywebstack}")
if [[ -n "${TWS_SYGNAL_PORT:-}" ]]; then
  cmd+=(--sygnal-port "${TWS_SYGNAL_PORT}")
fi

set +e
"${cmd[@]}"
rc=$?
set -e
if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
  exit "$rc"
fi
die "push credential configuration failed (exit ${rc})"
