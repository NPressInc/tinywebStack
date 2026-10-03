#!/usr/bin/env bash
# Derive Matrix client API host from Synapse homeserver.yaml when possible.
set -euo pipefail

# Optional extra curl args for matrix_client_base_url (e.g. --resolve, --cacert).
MATRIX_CLIENT_DISCOVER_CURL=()

matrix_client_base_url() {
  local main_domain=${1:-}
  local json=""
  if [[ ${#MATRIX_CLIENT_DISCOVER_CURL[@]} -gt 0 ]]; then
    json="$(curl -fsS "${MATRIX_CLIENT_DISCOVER_CURL[@]}" \
      "https://${main_domain}/.well-known/matrix/client" 2>/dev/null)" || true
  else
    json="$(curl -fsS "https://${main_domain}/.well-known/matrix/client" 2>/dev/null)" || true
  fi
  python3 - <<'PY' "$main_domain" "$json"
import json
import sys

main = sys.argv[1]
raw = sys.argv[2] if len(sys.argv) > 2 else ""
data = {}
if raw:
    try:
        parsed = json.loads(raw)
        data = parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        data = {}
base = (data.get("m.homeserver") or {}).get("base_url") or ""
base = base.rstrip("/")
print(base if base else f"https://{main}")
PY
}

matrix_public_host() {
  local main_domain=${1:-}
  local yaml="/etc/matrix-synapse/homeserver.yaml"
  if [[ -f "$yaml" ]]; then
    python3 - <<'PY' "$yaml" "$main_domain"
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    yaml = None
path = Path(sys.argv[1])
main = sys.argv[2]
if yaml and path.is_file():
    data = yaml.safe_load(path.read_text()) or {}
    name = data.get("server_name") or main
    print(name)
    sys.exit(0)
print(main or "localhost")
PY
    return 0
  fi
  if [[ -n "$main_domain" ]]; then
    echo "$main_domain"
  else
    echo "localhost"
  fi
}
