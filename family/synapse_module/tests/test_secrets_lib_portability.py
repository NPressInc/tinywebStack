"""Behavioral tests for the configurable-user / optional-CA helpers in scripts/lib/secrets.sh."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SECRETS_LIB = ROOT / "scripts" / "lib" / "secrets.sh"


def _bash(snippet: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full = f'source "{SECRETS_LIB}"; {snippet}'
    return subprocess.run(
        ["bash", "-c", full],
        check=False,
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", **(env or {})},
    )


def test_password_env_key_maps_dotted_names() -> None:
    out = _bash('printf "%s" "$(test_password_env_key mom.dad)"')
    assert out.returncode == 0, out.stderr
    assert out.stdout == "MOM_DAD_PASSWORD"


def test_password_env_key_maps_hyphenated_names() -> None:
    out = _bash('printf "%s" "$(test_password_env_key lil-kid_2)"')
    assert out.returncode == 0, out.stderr
    assert out.stdout == "LIL_KID_2_PASSWORD"


def test_validate_test_user_name_rejects_bad_names() -> None:
    for bad in ("Alice", "bad name", "stu#pid", ""):
        out = _bash(f'validate_test_user_name "{bad}" t 2>/dev/null; echo ok')
        assert out.returncode != 0 or "ok" not in out.stdout, f"accepted {bad!r}"


def test_validate_test_user_name_accepts_realistic_names() -> None:
    out = _bash('validate_test_user_name "mom.dad" t && echo ok')
    assert out.returncode == 0 and out.stdout.strip() == "ok", out.stderr


def test_user_test_password_prefers_username_derived_env() -> None:
    out = _bash(
        'printf "%s" "$(user_test_password family-a mom.dad)"',
        env={"MOM_DAD_PASSWORD": "from-env", "TW_STACK_SECRETS_FILE": "/nonexistent/passwords.env"},
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout == "from-env"


def test_user_test_password_falls_back_to_extra_env_key() -> None:
    # Legacy spark flow: PARENT_PASSWORD from passwords.env resolves for user "parent"
    # even before a username-derived key exists.
    out = _bash(
        'printf "%s" "$(user_test_password family-a parent PARENT_PASSWORD)"',
        env={"PARENT_PASSWORD": "legacy", "TW_STACK_SECRETS_FILE": "/nonexistent/passwords.env"},
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout == "legacy"


def test_resolve_ca_bundle_prefers_tws_ca_bundle(tmp_path) -> None:
    ca = tmp_path / "my-ca.pem"
    ca.write_text("PEM")
    out = _bash(
        'TW_STACK_ROOT=/nonexistent; printf "%s" "$(resolve_ca_bundle || true)"',
        env={"TWS_CA_BUNDLE": str(ca), "TW_STACK_SECRETS_DIR": str(tmp_path)},
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout == str(ca)


def test_resolve_ca_bundle_finds_lab_dir_ca(tmp_path) -> None:
    lab_dir = tmp_path / "lab-ca"
    lab_dir.mkdir()
    (lab_dir / "lab-ca.crt.pem").write_text("PEM")
    out = _bash(
        'TW_STACK_ROOT=/nonexistent; printf "%s" "$(resolve_ca_bundle || true)"',
        env={
            "TW_STACK_LAB_CA_DIR": str(lab_dir),
            "TW_STACK_SECRETS_DIR": str(tmp_path / "nope"),
        },
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout == str(lab_dir / "lab-ca.crt.pem")


def test_resolve_ca_bundle_returns_empty_without_any_ca(tmp_path) -> None:
    out = _bash(
        'TW_STACK_ROOT=/nonexistent; rc=0; ca="$(resolve_ca_bundle)" || rc=$?; '
        'printf "%s:%s" "$rc" "$ca"',
        env={
            "TW_STACK_SECRETS_DIR": str(tmp_path / "nope"),
            "TW_STACK_LAB_CA_DIR": str(tmp_path / "nope2"),
        },
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout == "1:"  # rc=1, empty path -> caller uses system trust store


def test_require_ca_bundle_or_die_hard_fails_only_when_required(tmp_path) -> None:
    out = _bash(
        'require_ca_bundle_or_die "" 2>/dev/null; echo survived',
        env={"TWS_REQUIRE_LAB_CA": "1"},
    )
    assert out.returncode != 0 and "survived" not in out.stdout

    out = _bash('require_ca_bundle_or_die "" && echo survived', env={"TWS_REQUIRE_LAB_CA": "0"})
    assert out.returncode == 0 and "survived" in out.stdout
