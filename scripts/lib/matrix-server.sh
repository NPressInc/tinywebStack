#!/usr/bin/env bash
# Derive Matrix client API host from Synapse homeserver.yaml when possible.
set -euo pipefail

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
