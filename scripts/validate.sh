#!/usr/bin/env bash
# Local validation (no libvirt/YunoHost required).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TW_STACK_ROOT"

echo "== bash -n =="
while IFS= read -r -d '' f; do
  bash -n "$f"
  echo "  OK $f"
done < <(find scripts -name '*.sh' -print0)

echo "== shellcheck (optional) =="
if command -v shellcheck >/dev/null 2>&1; then
  find scripts -name '*.sh' -print0 | xargs -0 shellcheck -x
else
  echo "  shellcheck not installed — skipped"
fi

echo "== DRY_RUN deploy =="
export DRY_RUN=1
cp -f config/nodes.conf.example config/nodes.conf
bash scripts/spark/deploy-test-nodes.sh
bash scripts/spark/render-cloud-init.sh family-a family-a.family.test /tmp/tws-seed-test
test -f /tmp/tws-seed-test/user-data.rendered || test -f /tmp/tws-seed-test/cloud-init.iso || {
  echo "seed render missing"; exit 1
}
echo "  cloud-init rendered"

echo "== federation template yaml =="
python3 - <<'PY'
import yaml, sys
from pathlib import Path
p = Path("templates/synapse/tinywebstack-federation.yaml.example")
yaml.safe_load(p.read_text())
print("  YAML OK", p)
PY

echo "All local checks passed."
