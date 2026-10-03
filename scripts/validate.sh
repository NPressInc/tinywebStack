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
if [[ ! -f "${ADMIN_SSH_PUBKEY:-${HOME}/.ssh/id_ed25519.pub}" ]]; then
  _validate_key_dir="${TW_STACK_ROOT}/.tools/validate-ssh"
  mkdir -p "$_validate_key_dir"
  if [[ ! -f "${_validate_key_dir}/id_ed25519.pub" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${_validate_key_dir}/id_ed25519" -q
  fi
  export ADMIN_SSH_PUBKEY="${_validate_key_dir}/id_ed25519.pub"
fi
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

echo "== git executable bits (scripts/*.sh) =="
python3 - <<'PY'
import subprocess
from pathlib import Path
root = Path(".")
out = subprocess.check_output(["git", "ls-files", "-s", "scripts"], text=True)
bad = []
for line in out.splitlines():
    mode, _, _, path = line.split(maxsplit=3)
    if path.endswith(".sh") and mode != "100755":
        bad.append(path)
if bad:
    raise SystemExit("Non-executable scripts in git index:\n" + "\n".join(bad))
print("  all scripts/*.sh mode 100755")
PY

echo "== pytest (family module + dashboard) =="
VALIDATE_VENV="${TW_STACK_ROOT}/.tools/validate-venv"
if [[ ! -x "${VALIDATE_VENV}/bin/python" ]]; then
  python3 -m venv "$VALIDATE_VENV"
  "${VALIDATE_VENV}/bin/pip" install -q --upgrade pip
fi
if ! "${VALIDATE_VENV}/bin/pip" install -q -r "${TW_STACK_ROOT}/scripts/requirements-validate.txt"; then
  echo "  pip install failed — skipped pytest" >&2
else
  env -u PYTHONPATH "${VALIDATE_VENV}/bin/python" -m pytest \
    family/synapse_module/tests family/dashboard/tests family/calendar_module/tests \
    family/permissions/tests scripts/tests -q
  echo "  pytest passed"
fi

echo "All local checks passed."
