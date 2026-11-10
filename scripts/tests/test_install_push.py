"""install-push.sh and tinyweb.env push settings."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL_PUSH = ROOT / "scripts" / "vm" / "install-push.sh"
INSTALL_TINYWEB = ROOT / "scripts" / "install-tinyweb.sh"


def test_install_push_script_exists() -> None:
    assert INSTALL_PUSH.is_file()
    text = INSTALL_PUSH.read_text(encoding="utf-8")
    assert "tinywebstack-ntfy" in text
    assert "tinywebstack-sygnal" in text
    assert "auth-default-access: deny-all" in text
    assert "SYGNAL_CONF=" in text
    assert "configure-push-credentials.sh" in text
    assert "TWS_PUSH_CREDENTIAL_SOURCE:-tinyweb" in text
    assert "sygnal_apns_enabled" not in text
    hook = ROOT / "scripts" / "vm" / "configure-push-credentials.sh"
    assert hook.is_file()
    hook_text = hook.read_text(encoding="utf-8")
    assert "push_operator_config.py" in hook_text
    assert "Delivery is not configured" in hook_text or "exit 2" in hook_text


def test_install_tinyweb_calls_push_step() -> None:
    text = INSTALL_TINYWEB.read_text(encoding="utf-8")
    assert "install-push.sh" in text
    assert "tinywebstack-ntfy" in text


def test_push_versions_pinned() -> None:
    versions = (ROOT / "config" / "push-versions.env").read_text(encoding="utf-8")
    assert "TWS_NTFY_VERSION=" in versions
    assert "TWS_NTFY_SHA256_amd64=" in versions
    assert "TWS_SYGNAL_GIT_REF=" in versions
