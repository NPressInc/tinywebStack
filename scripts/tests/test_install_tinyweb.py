"""Tests for scripts/install-tinyweb.sh (no YunoHost required)."""

from __future__ import annotations

import os
import re
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "scripts" / "install-tinyweb.sh"
INSTALL_LIBS = (
    ROOT / "scripts" / "install-tinyweb.sh",
    ROOT / "scripts" / "lib" / "tinyweb-install-secrets.sh",
    ROOT / "scripts" / "lib" / "tinyweb-install-env.sh",
)
INSTALL_STEPS_ORDER = [
    "0 preflight",
    "1 swapfile",
    "2 yunohost-bootstrap",
    "3 tls",
    "4 yunohost-family-apps",
    "5 create-matrix-test-users (lab only)",
    "6 family-init",
    "7 family-permissions-seed and family-federation-state-seed",
    "8 mobilizon-admin-password",
    "9 family-sync-federation and family-events-perms",
    "10 self-check",
]


def _run_install(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    merged = {**os.environ, **env}
    return subprocess.run(
        ["bash", str(INSTALL), *args],
        cwd=ROOT,
        env=merged,
        text=True,
        capture_output=True,
        check=False,
    )


def _write_env(tmp_path: Path, lines: str) -> Path:
    p = tmp_path / "tinyweb.env"
    p.write_text(lines, encoding="utf-8")
    return p


def test_dry_run_skips_preflight_apt_install() -> None:
    text = INSTALL.read_text(encoding="utf-8")
    assert "ensure_preflight_base_packages" in text
    preflight = text[text.find("step_preflight()") : text.find("step_bootstrap()")]
    assert "ensure_preflight_base_packages" in preflight
    dry_idx = preflight.find('DRY_RUN:-0}" != "1"')
    apt_idx = preflight.find("ensure_preflight_base_packages")
    assert dry_idx >= 0 and apt_idx > dry_idx


def test_dry_run_lists_steps_in_order(tmp_path: Path) -> None:
    cfg = _write_env(
        tmp_path,
        "TWS_DOMAIN=family-a.family.test\nTWS_MODE=lab\nLAB_PASSWORD=labsecret8\n",
    )
    proc = _run_install({}, "--dry-run", "--config", str(cfg))
    assert proc.returncode == 0, proc.stderr
    log = proc.stderr
    positions = []
    for step in INSTALL_STEPS_ORDER:
        idx = log.find(step)
        assert idx >= 0, f"missing step line: {step}\n{log}"
        positions.append(idx)
    assert positions == sorted(positions), "steps out of order"
    assert "labsecret8" not in log and "LAB_PASSWORD=labsecret" not in log


def test_lab_password_rejected_in_production(tmp_path: Path) -> None:
    cfg = _write_env(
        tmp_path,
        "TWS_DOMAIN=home.example.com\nTWS_MODE=production\nLAB_PASSWORD=labsecret8\n",
    )
    proc = _run_install({}, "--config", str(cfg))
    assert proc.returncode != 0
    assert "LAB_PASSWORD" in proc.stderr


def test_missing_tws_domain_fails(tmp_path: Path) -> None:
    cfg = _write_env(tmp_path, "TWS_MODE=lab\n")
    proc = _run_install({}, "--config", str(cfg))
    assert proc.returncode != 0
    assert "TWS_DOMAIN" in proc.stderr


def test_dry_run_owntracks_plan_excludes_traccar(tmp_path: Path) -> None:
    cfg = _write_env(
        tmp_path,
        "TWS_DOMAIN=family-a.family.test\nTWS_MODE=lab\nLOCATION_APP=owntracks\n",
    )
    proc = _run_install({}, "--dry-run", "--config", str(cfg))
    assert proc.returncode == 0, proc.stderr
    assert "will not install traccar" in proc.stderr.lower()


def test_install_scripts_never_force_bare_set_x() -> None:
    pat = re.compile(r"^\s*set -x\s*$")
    for path in INSTALL_LIBS:
        for line in path.read_text(encoding="utf-8").splitlines():
            assert not pat.match(line), f"bare set -x in {path}: {line!r}"


def test_install_secrets_file_mode_and_umask(tmp_path: Path) -> None:
    etc = tmp_path / "etc"
    secrets = etc / "secrets"
    env_file = {
        "TWS_ETC_DIR": str(etc),
        "TWS_DOMAIN": "family-a.family.test",
        "TWS_MODE": "lab",
        "LAB_PASSWORD": "labsecret8",
        "TWS_FAMILY_USERS": "parent,kid",
        "LOCATION_APP": "owntracks",
    }
    script = r"""
set -euo pipefail
source scripts/lib/tinyweb-install-env.sh
source scripts/lib/tinyweb-install-secrets.sh
export TWS_ETC_DIR TWS_DOMAIN TWS_MODE LAB_PASSWORD TWS_FAMILY_USERS LOCATION_APP
apply_tinyweb_env_defaults
ensure_tinyweb_install_secrets "$TWS_DOMAIN" "$TWS_MODE" "$LOCATION_APP"
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={k: v for k, v in {**os.environ, **env_file}.items() if k != "DRY_RUN"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    install_env = secrets / "install.env"
    assert install_env.is_file()
    mode = stat.S_IMODE(install_env.stat().st_mode)
    assert mode == 0o600
    body = install_env.read_text(encoding="utf-8")
    assert "YUNOHOST_ADMIN_PASSWORD=" in body
    assert "labsecret8" not in (proc.stdout + proc.stderr)
    assert re.search(r"^YUNOHOST_ADMIN_PASSWORD=", body, re.M)


def test_write_install_secret_merge_preserves_umask(tmp_path: Path) -> None:
    etc = tmp_path / "etc-umask"
    env_file = {
        "TWS_ETC_DIR": str(etc),
        "TWS_DOMAIN": "family-a.family.test",
        "TWS_MODE": "production",
    }
    script = r"""
set -euo pipefail
source scripts/lib/tinyweb-install-env.sh
source scripts/lib/tinyweb-install-secrets.sh
export TWS_ETC_DIR TWS_DOMAIN TWS_MODE
apply_tinyweb_env_defaults
before="$(umask)"
write_install_secret_merge UMASK_PROBE_KEY "abcdefghijklmnopQRSTuvwx"
after="$(umask)"
[[ "$before" == "$after" ]]
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={k: v for k, v in {**os.environ, **env_file}.items() if k != "DRY_RUN"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout


def test_generated_install_password_alphanumeric_roundtrip(tmp_path: Path) -> None:
    etc = tmp_path / "etc-pw"
    env_file = {
        "TWS_ETC_DIR": str(etc),
        "TWS_DOMAIN": "home.example.com",
        "TWS_MODE": "production",
    }
    script = r"""
set -euo pipefail
source scripts/lib/tinyweb-install-env.sh
source scripts/lib/tinyweb-install-secrets.sh
export TWS_ETC_DIR TWS_DOMAIN TWS_MODE
apply_tinyweb_env_defaults
pw="$(generate_install_password)"
[[ ${#pw} -eq 24 ]]
[[ "$pw" =~ ^[A-Za-z0-9]{24}$ ]]
write_install_secret_merge ROUNDTRIP_KEY "$pw"
read_back="$(read_install_secret ROUNDTRIP_KEY)"
[[ "$read_back" == "$pw" ]]
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={k: v for k, v in {**os.environ, **env_file}.items() if k != "DRY_RUN"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout


def test_install_secrets_idempotent(tmp_path: Path) -> None:
    etc = tmp_path / "etc2"
    env_file = {
        "TWS_ETC_DIR": str(etc),
        "TWS_DOMAIN": "family-a.family.test",
        "TWS_MODE": "lab",
        "LAB_PASSWORD": "labsecret8",
        "LOCATION_APP": "owntracks",
    }
    script = r"""
set -euo pipefail
source scripts/lib/tinyweb-install-env.sh
source scripts/lib/tinyweb-install-secrets.sh
export TWS_ETC_DIR TWS_DOMAIN TWS_MODE LAB_PASSWORD LOCATION_APP
apply_tinyweb_env_defaults
first_copy="${TMPDIR:-/tmp}/tws-install-first-$$.env"
ensure_tinyweb_install_secrets "$TWS_DOMAIN" "$TWS_MODE" "$LOCATION_APP"
cp "$(tinyweb_install_env_path)" "$first_copy"
ensure_tinyweb_install_secrets "$TWS_DOMAIN" "$TWS_MODE" "$LOCATION_APP"
cmp "$(tinyweb_install_env_path)" "$first_copy"
rm -f "$first_copy"
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={k: v for k, v in {**os.environ, **env_file}.items() if k != "DRY_RUN"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout


def test_preflight_base_pkg_present_uses_dpkg_status() -> None:
    text = INSTALL.read_text(encoding="utf-8")
    block = text[text.find("preflight_base_pkg_present()") : text.find("ensure_preflight_base_packages()")]
    assert "command -v" not in block
    assert "install ok installed" in block


def test_ensure_preflight_warns_on_update_failure(tmp_path: Path) -> None:
    text = INSTALL.read_text(encoding="utf-8")
    block = text[text.find("ensure_preflight_base_packages()") : text.find("step_swapfile()")]
    assert "WARN: apt-get update failed" in block
    assert "Missing base packages after install attempt" in block


def test_preflight_skips_apt_when_dpkg_reports_installed(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    apt_log = tmp_path / "apt.log"

    def _write(name: str, body: str) -> None:
        p = bin_dir / name
        p.write_text(body, encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    _write(
        "dpkg",
        """#!/bin/sh
case "$1" in
  -s)
    case "$2" in
      rsync|curl|openssl|ca-certificates|gnupg)
        echo 'Status: install ok installed'
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exit 1
""",
    )
    _write(
        "apt-get",
        f"""#!/bin/sh
echo "apt-get $*" >>"{apt_log}"
exit 99
""",
    )

    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
ensure_preflight_base_packages
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        },
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert not apt_log.exists() or apt_log.read_text(encoding="utf-8") == ""


def test_preflight_update_failure_still_installs(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    apt_log = tmp_path / "apt.log"

    def _write(name: str, body: str) -> None:
        p = bin_dir / name
        p.write_text(body, encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    _write(
        "dpkg",
        """#!/bin/sh
case "$1" in
  -s)
    case "$2" in
      gnupg) exit 1 ;;
      rsync|curl|openssl|ca-certificates)
        echo 'Status: install ok installed'
        exit 0
        ;;
    esac
    exit 1
    ;;
esac
exit 1
""",
    )
    _write(
        "apt-get",
        f"""#!/bin/sh
echo "apt-get $*" >>"{apt_log}"
case "$1" in
  update) exit 100 ;;
  install) exit 0 ;;
esac
exit 1
""",
    )

    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
ensure_preflight_base_packages
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        },
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    log = apt_log.read_text(encoding="utf-8")
    assert "apt-get update" in log
    assert "apt-get install" in log
    assert "WARN: apt-get update failed" in proc.stderr


def test_preflight_dies_when_install_fails_and_pkg_still_missing(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()

    def _write(name: str, body: str) -> None:
        p = bin_dir / name
        p.write_text(body, encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    _write(
        "dpkg",
        """#!/bin/sh
case "$1" in
  -s) exit 1 ;;
esac
exit 1
""",
    )
    _write(
        "apt-get",
        """#!/bin/sh
case "$1" in
  update) exit 0 ;;
  install) exit 1 ;;
esac
exit 1
""",
    )

    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
ensure_preflight_base_packages
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
        },
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode != 0
    assert "Missing base packages after install attempt" in proc.stderr


def test_systemd_unit_file_present_parses_list_unit_files() -> None:
    text = INSTALL.read_text(encoding="utf-8")
    block = text[text.find("systemd_unit_file_present()") : text.find("selfcheck_require_unit()")]
    assert "list-unit-files --no-legend" in block
    assert "awk '{print $1}'" in block
    assert "grep -qxF" in block


def test_selfcheck_systemd_detection_with_stub(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()

    def _write(name: str, body: str) -> None:
        p = bin_dir / name
        p.write_text(body, encoding="utf-8")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    _write(
        "systemctl",
        """#!/bin/sh
case "$1" in
  list-unit-files)
    for unit in "$@"; do
      case "$unit" in --no-legend) continue ;; esac
    done
    case "$unit" in
      nginx.service) echo "nginx.service enabled enabled" ;;
      missing.service) echo "other.service enabled enabled" ;;
      *) exit 0 ;;
    esac
    exit 0
    ;;
  is-active) exit 0 ;;
esac
exit 1
""",
    )

    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
systemd_unit_file_present nginx.service || exit 10
systemd_unit_file_present missing.service && exit 11
exit 0
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={**os.environ, "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout


def test_selfcheck_require_unit_reports_missing(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "systemctl").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (bin_dir / "systemctl").chmod(0o755)

    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
out="$(selfcheck_require_unit nginx || true)"
[[ "$out" == FAIL*nginx*missing* ]]
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env={**os.environ, "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}"},
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout


def test_swap_decision_logic(tmp_path: Path) -> None:
    script = r"""
set -euo pipefail
export TWS_INSTALL_NO_MAIN=1
source scripts/install-tinyweb.sh
export TWS_MEMTOTAL_KB_OVERRIDE=4000000
export TWS_SWAPTOTAL_KB_OVERRIDE=0
export TWS_SWAP=auto
if should_create_swap auto; then echo SWAP_YES; else echo SWAP_NO; fi
export TWS_MEMTOTAL_KB_OVERRIDE=8000000
if should_create_swap auto; then echo HIGH_YES; else echo HIGH_NO; fi
export TWS_SWAP=off
if should_create_swap off; then echo OFF_YES; else echo OFF_NO; fi
"""
    env = {k: v for k, v in os.environ.items() if k != "DRY_RUN"}
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "SWAP_YES" in out
    assert "HIGH_NO" in out
    assert "OFF_NO" in out


def test_selfcheck_includes_family_public_nginx_checks() -> None:
    text = INSTALL.read_text(encoding="utf-8")
    assert "tinywebstack-family.json" in text
    assert "family invite verify public HTTP 400" in text
    assert "family well-known HTTP 200" in text
    assert "matrix client well-known HTTP 200" in text
    assert "matrix_client_base_url" in text
    assert "--resolve" in text
    block = text[text.find("step_selfcheck()") : text.find("print_dry_run_plan()")]
    assert "/family/api/invite/verify" in block
    assert "POST" in block
