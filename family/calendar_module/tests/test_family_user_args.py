"""Argument handling for family member provisioning (--users / TWS_FAMILY_USERS).

Runs the real scripts/vm/*.sh in a sandboxed copy of the scripts tree with a
fake `id` (pretends root) and a stub `yunohost` that records invocations, so
the lab default (parent,kid) and arbitrary real-named households can both be
exercised without YunoHost.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]

# Keys that could leak real config into the sandboxed scripts.
_LEAKY_PREFIXES = ("TWS_FAMILY_",)
_LEAKY_SUFFIXES = ("_PASSWORD",)


def _make_root(tmp_path: Path) -> Path:
    """Sandbox scripts tree: root/vm/*.sh, root/lib/*.sh, root/config/defaults.env."""
    root = tmp_path / "tws"
    shutil.copytree(ROOT / "scripts" / "lib", root / "lib")
    shutil.copytree(ROOT / "scripts" / "vm", root / "vm")
    (root / "config").mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "config" / "defaults.env", root / "config" / "defaults.env")
    return root


def _stub_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "id").write_text("#!/usr/bin/env bash\necho 0\n", encoding="utf-8")
    (bin_dir / "yunohost").write_text(
        "#!/usr/bin/env bash\n"
        'printf \'%s\\n\' "$*" >> "$STUB_LOG"\n'
        'if [[ "$1 $2 $3" == "user list --output-as" ]]; then echo \'{"users":{}}\'; fi\n'
        "exit 0\n",
        encoding="utf-8",
    )
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    return bin_dir


def _run(tmp_path: Path, root: Path, script: str, args: list[str], **extra_env: str):
    stub_log = tmp_path / "yunohost.log"
    stub_log.touch()
    env = {
        k: v
        for k, v in os.environ.items()
        if not (k.startswith(_LEAKY_PREFIXES) or k.endswith(_LEAKY_SUFFIXES))
    }
    env.update(
        {
            "PATH": f"{_stub_bin(tmp_path)}:{env.get('PATH', '/usr/bin:/bin')}",
            "HOME": str(tmp_path),
            "STUB_LOG": str(stub_log),
            "TW_STACK_SECRETS_DIR": str(tmp_path / "secrets"),
            "TW_STACK_SECRETS_FILE": str(tmp_path / "secrets" / "passwords.env"),
        }
    )
    env.update(extra_env)
    proc = subprocess.run(
        ["bash", str(root / "vm" / script), *args],
        capture_output=True,
        text=True,
        env=env,
    )
    proc.stub_log = stub_log.read_text(encoding="utf-8")  # type: ignore[attr-defined]
    return proc


@pytest.fixture()
def sandbox(tmp_path: Path):
    root = _make_root(tmp_path)
    return tmp_path, root


def _log_lines(proc) -> list[str]:
    return [ln for ln in proc.stub_log.splitlines() if ln.strip()]


# --- create-family-test-users.sh ------------------------------------------


def test_create_users_default_flow_is_lab_pair(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["family.test", "family-a"],
        PARENT_PASSWORD="dummydummy",
        KID_PASSWORD="dummydummy",
    )
    assert proc.returncode == 0, proc.stderr
    lines = _log_lines(proc)
    assert any(ln.startswith("user create parent ") for ln in lines)
    assert any(ln.startswith("user create kid ") for ln in lines)
    assert "user group add parents parent" in lines
    assert "user group add kids kid" in lines


def test_create_users_cli_flag_creates_arbitrary_household(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users", " william , sophie ,emma "],
        TWS_FAMILY_PARENTS="william,sophie",
        TWS_FAMILY_KIDS="emma",
        WILLIAM_PASSWORD="dummydummy",
        SOPHIE_PASSWORD="dummydummy",
        EMMA_PASSWORD="dummydummy",
    )
    assert proc.returncode == 0, proc.stderr
    lines = _log_lines(proc)
    assert any(ln.startswith("user create william ") for ln in lines)
    assert any(ln.startswith("user create sophie ") for ln in lines)
    assert any(ln.startswith("user create emma ") for ln in lines)
    assert not any(ln.startswith("user create parent ") for ln in lines)
    assert not any(ln.startswith("user create kid ") for ln in lines)
    assert "user group add parents william" in lines
    assert "user group add parents sophie" in lines
    assert "user group add kids emma" in lines


def test_create_users_env_var_list(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home"],
        TWS_FAMILY_USERS="william,sophie",
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="sophie",
        WILLIAM_PASSWORD="dummydummy",
        SOPHIE_PASSWORD="dummydummy",
    )
    assert proc.returncode == 0, proc.stderr
    lines = _log_lines(proc)
    assert any(ln.startswith("user create william ") for ln in lines)
    assert any(ln.startswith("user create sophie ") for ln in lines)


def test_create_users_cli_flag_beats_env(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users=william"],
        TWS_FAMILY_USERS="sophie,emma",
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="",
        WILLIAM_PASSWORD="dummydummy",
    )
    assert proc.returncode == 0, proc.stderr
    lines = _log_lines(proc)
    assert any(ln.startswith("user create william ") for ln in lines)
    assert not any(ln.startswith("user create sophie ") for ln in lines)


def test_create_users_missing_password_dies_with_user_name(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users", "william,nope"],
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="nope",
        WILLIAM_PASSWORD="dummydummy",
    )
    assert proc.returncode != 0
    assert "NOPE_PASSWORD" in proc.stderr


def test_create_users_rejects_invalid_name(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users", "Parent"],
        PARENT_PASSWORD="dummydummy",
    )
    assert proc.returncode != 0
    assert "Invalid family user name 'Parent'" in proc.stderr


def test_create_users_rejects_empty_list(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users", " , , "],
    )
    assert proc.returncode != 0
    assert "Empty family user list" in proc.stderr


def test_create_users_dedupes_list(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "create-family-test-users.sh",
        ["home.example", "home", "--users", "william,william,sophie"],
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="sophie",
        WILLIAM_PASSWORD="dummydummy",
        SOPHIE_PASSWORD="dummydummy",
    )
    assert proc.returncode == 0, proc.stderr
    lines = _log_lines(proc)
    assert sum(1 for ln in lines if ln.startswith("user create william ")) == 1


def test_create_users_usage_without_args(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(tmp_path, root, "create-family-test-users.sh", [])
    assert proc.returncode == 1
    assert "Usage: create-family-test-users.sh" in proc.stdout


# --- setup-family-calendars.sh ---------------------------------------------


def test_setup_calendars_default_still_parent_kid(sandbox) -> None:
    """Defaults must reach the Nextcloud occ probe (next step past all new parsing)
    with the lab owner (parent) — proving the spark flow is unchanged."""
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "setup-family-calendars.sh",
        ["family.test", "family-a"],
        PARENT_PASSWORD="dummydummy",
    )
    assert proc.returncode != 0
    assert "Nextcloud occ not found" in proc.stderr
    assert "Invalid family user name" not in proc.stderr


def test_setup_calendars_custom_users_parse(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "setup-family-calendars.sh",
        ["home.example", "home", "--users", "william,sophie"],
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="sophie",
        WILLIAM_PASSWORD="dummydummy",
    )
    assert proc.returncode != 0
    # Owner is the first user; password lookup must accept WILLIAM_PASSWORD.
    assert "Nextcloud occ not found" in proc.stderr
    assert "Password for calendar owner" not in proc.stderr


def test_setup_calendars_owner_password_required_when_missing(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "setup-family-calendars.sh",
        ["home.example", "home", "--users", "william"],
        TWS_FAMILY_PARENTS="william",
        TWS_FAMILY_KIDS="",
    )
    assert proc.returncode != 0
    assert "WILLIAM_PASSWORD" in proc.stderr


def test_setup_calendars_invalid_name_rejected_before_occ(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(
        tmp_path,
        root,
        "setup-family-calendars.sh",
        ["home.example", "home", "--users", "bad;name"],
        WILLIAM_PASSWORD="dummydummy",
    )
    assert proc.returncode != 0
    assert "Invalid family user name" in proc.stderr
    assert "Nextcloud occ not found" not in proc.stderr


def test_setup_calendars_usage_without_args(sandbox) -> None:
    tmp_path, root = sandbox
    proc = _run(tmp_path, root, "setup-family-calendars.sh", ["only-one"])
    assert proc.returncode == 1
    assert "Usage: setup-family-calendars.sh" in proc.stdout


# --- scripts/lib/family_users.sh (unit level) -------------------------------


def _bash(tmp_path: Path, snippet: str, **env: str) -> subprocess.CompletedProcess:
    lib = ROOT / "scripts" / "lib" / "family_users.sh"
    common = ROOT / "scripts" / "lib" / "common.sh"
    e = {
        k: v
        for k, v in os.environ.items()
        if not (k.startswith(_LEAKY_PREFIXES) or k.endswith(_LEAKY_SUFFIXES))
    }
    for key in list(e):
        if key.startswith("TWS_FAMILY_"):
            del e[key]
    e.update(env)
    return subprocess.run(
        ["bash", "-c", f'source "{common}"; source "{lib}"; {snippet}'],
        capture_output=True,
        text=True,
        env=e,
    )


def test_lib_resolve_users_precedence(tmp_path: Path) -> None:
    out = _bash(
        tmp_path,
        'resolve_family_users --users "c,a" ',
        TWS_FAMILY_USERS="x,y",
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "c,a"


def test_lib_resolve_users_env_when_no_flag(tmp_path: Path) -> None:
    out = _bash(tmp_path, "resolve_family_users", TWS_FAMILY_USERS=" william , sophie ,, william ")
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == "william,sophie"


def test_lib_resolve_users_default(tmp_path: Path) -> None:
    out = _bash(tmp_path, "resolve_family_users")
    assert out.stdout.strip() == "parent,kid"


def test_lib_custom_users_require_explicit_roles(tmp_path: Path) -> None:
    out = _bash(
        tmp_path,
        'assert_family_roles_configured "william,sophie" || exit 1',
        TWS_FAMILY_USERS="william,sophie",
    )
    assert out.returncode != 0
    assert "TWS_FAMILY_PARENTS" in out.stderr


def test_lib_owner_and_splits(tmp_path: Path) -> None:
    out = _bash(tmp_path, 'resolve_family_owner "william,sophie,emma"')
    assert out.stdout.strip() == "william"
    out = _bash(tmp_path, 'resolve_family_owner "william,sophie"', TWS_FAMILY_OWNER="sophie")
    assert out.stdout.strip() == "sophie"
    out = _bash(tmp_path, 'resolve_family_parents "parent,kid"')
    assert out.stdout.strip() == "parent"
    out = _bash(tmp_path, 'resolve_family_kids "parent,kid"')
    assert out.stdout.strip() == "kid"
    out = _bash(
        tmp_path,
        'resolve_family_kids "william,sophie,emma"',
        TWS_FAMILY_PARENTS="william,sophie",
        TWS_FAMILY_KIDS="emma",
    )
    assert out.stdout.strip() == "emma"
    out = _bash(tmp_path, 'resolve_family_kids "william"', TWS_FAMILY_KIDS="")
    assert out.stdout.strip() == ""
