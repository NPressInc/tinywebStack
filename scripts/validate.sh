#!/usr/bin/env bash
# Local validation (no libvirt/YunoHost required).
set -euo pipefail

TW_STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TW_STACK_ROOT"

install_shellcheck() {
  local sc_dir="${TW_STACK_ROOT}/.tools/shellcheck"
  local sc_bin="${sc_dir}/shellcheck"
  if [[ -x "$sc_bin" ]]; then
    echo "$sc_bin"
    return 0
  fi
  if command -v shellcheck >/dev/null 2>&1; then
    command -v shellcheck
    return 0
  fi
  mkdir -p "$sc_dir"
  local arch url
  arch="$(uname -m)"
  case "$arch" in
    x86_64) url="https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz" ;;
    aarch64) url="https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.aarch64.tar.xz" ;;
    *)
      echo "  shellcheck: no binary for ${arch} — skipped" >&2
      return 1
      ;;
  esac
  curl -fsSL "$url" | tar -xJ -C "$sc_dir" --strip-components=1
  echo "$sc_bin"
}

echo "== bash -n =="
while IFS= read -r -d '' f; do
  bash -n "$f"
  echo "  OK $f"
done < <(find scripts -name '*.sh' -print0)

echo "== shellcheck =="
if sc="$(install_shellcheck)"; then
  find scripts -name '*.sh' -print0 | xargs -0 "$sc" -x
  echo "  shellcheck passed"
else
  echo "  shellcheck skipped"
fi

echo "== DRY_RUN deploy =="
export DRY_RUN=1
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
export TW_STACK_VM_DIR="${TW_STACK_VM_DIR:-/tmp/tinywebstack-vms-dryrun}"
export TW_STACK_IMAGE_DIR="${TW_STACK_IMAGE_DIR:-/tmp/tinywebstack-images-dryrun}"
export TW_NODES_CONF="${TW_NODES_CONF:-config/nodes.conf}"
if [[ ! -f "$TW_NODES_CONF" ]]; then
  TW_NODES_CONF="$(mktemp)"
  cp config/nodes.conf.example "$TW_NODES_CONF"
  export TW_NODES_CONF
  echo "  (using ephemeral ${TW_NODES_CONF})"
fi
bash scripts/spark/deploy-test-nodes.sh

bash scripts/spark/render-cloud-init.sh family-a family-a.family.test /tmp/tws-seed-test
test -f /tmp/tws-seed-test/user-data.rendered || test -f /tmp/tws-seed-test/cloud-init.iso || {
  echo "seed render missing"; exit 1
}
echo "  cloud-init rendered"

echo "== federation template yaml =="
python3 - <<'PY'
import yaml
from pathlib import Path
p = Path("templates/synapse/tinywebstack-federation.yaml.example")
yaml.safe_load(p.read_text())
print("  YAML OK", p)
PY

echo "All local checks passed."
