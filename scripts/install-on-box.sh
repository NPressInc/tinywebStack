#!/usr/bin/env bash
# One-box installer entrypoint: resolve <family>.tinyweb.win and delegate to install-tinyweb.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tinyweb-install-env.sh
source "${REPO_ROOT}/scripts/lib/tinyweb-install-env.sh"

usage() {
  cat <<'EOF'
Usage: install-on-box.sh [--family <slug-or-domain>] [--domain <slug-or-domain>] [<slug-or-domain>] [install-tinyweb options...]

Resolves a bare family slug (e.g. smith) to smith.tinyweb.win, then runs scripts/install-tinyweb.sh.
Examples:
  install-on-box.sh smith --dry-run
  install-on-box.sh --family smith --dry-run
EOF
  exit 1
}

FAMILY_ARG=""
PASS_THROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --family|--domain)
      FAMILY_ARG=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      PASS_THROUGH+=("$@")
      break
      ;;
    -*)
      PASS_THROUGH+=("$1")
      shift
      ;;
    *)
      if [[ -z "$FAMILY_ARG" ]]; then
        FAMILY_ARG=$1
        shift
      else
        PASS_THROUGH+=("$1")
        shift
      fi
      ;;
  esac
done

if [[ -z "$FAMILY_ARG" ]]; then
  usage
fi

TWS_BASE_DOMAIN="${TWS_BASE_DOMAIN:-tinyweb.win}"
RESOLVED="$(resolve_tws_domain "$FAMILY_ARG" "$TWS_BASE_DOMAIN")"

if ((${#PASS_THROUGH[@]} > 0)); then
  exec bash "${REPO_ROOT}/scripts/install-tinyweb.sh" --domain "$RESOLVED" "${PASS_THROUGH[@]}"
else
  exec bash "${REPO_ROOT}/scripts/install-tinyweb.sh" --domain "$RESOLVED"
fi
