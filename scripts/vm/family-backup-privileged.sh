#!/usr/bin/env bash
# Narrow root helper for TinyWeb backups. www-data may run only this script.
# Subcommands are fixed. Arguments are passed through as argv, never via a shell.
set -euo pipefail

if [[ "${TWS_PRIVILEGED_ALLOW_NON_ROOT:-}" != "1" ]] && [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

PY="${TWS_DASHBOARD_PYTHON:-/opt/tinywebstack-family-dashboard/venv/bin/python}"
if [[ ! -x "$PY" ]]; then
  echo "Dashboard Python is not installed" >&2
  exit 1
fi

usage() {
  echo "Usage: family-backup-privileged.sh preflight|list-archives|run-backup JOB|run-scheduled|cat-archive ID|copy-archive JOB|apply-schedule" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift

case "$cmd" in
  preflight|list-archives|run-scheduled|apply-schedule)
    [[ $# -eq 0 ]] || usage
    ;;
  run-backup|copy-archive)
    [[ $# -eq 1 ]] || usage
    [[ "$1" =~ ^[0-9a-f]{32}$ ]] || usage
    ;;
  cat-archive)
    [[ $# -eq 1 ]] || usage
    [[ "$1" =~ ^tinyweb-[0-9]{8}-[0-9]{6}$ ]] || usage
    ;;
  *)
    usage
    ;;
esac

exec "$PY" -m tinywebstack_dashboard.backup_cli "$cmd" "$@"
