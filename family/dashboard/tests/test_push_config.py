"""Push enrollment config (no secrets in API)."""

from __future__ import annotations

import os

from tinywebstack_dashboard.push_config import (
    android_app_id,
    enroll_push_section,
    ios_app_id,
    push_enabled,
)


def test_push_enabled_default() -> None:
    os.environ.pop("TWS_PUSH_ENABLE", None)
    assert push_enabled() is True
    os.environ["TWS_PUSH_ENABLE"] = "0"
    assert push_enabled() is False


def test_enroll_push_section_urls() -> None:
    os.environ["TWS_PUSH_ENABLE"] = "1"
    os.environ["TWS_NTFY_PORT"] = "8090"
    os.environ["TWS_SYGNAL_PORT"] = "5000"
    os.environ["TWS_APNS_BUNDLE_ID"] = "win.tinyweb.tinyweb"
    section = enroll_push_section("family.test")
    assert section is not None
    assert section["unifiedpush"]["gateway_url"] == (
        "http://127.0.0.1:8090/_matrix/push/v1/notify"
    )
    assert section["sygnal"]["gateway_url"] == (
        "http://127.0.0.1:5000/_matrix/push/v1/notify"
    )
    assert section["sygnal"]["ios_app_id"] == ios_app_id()
    assert section["sygnal"]["android_app_id"] == android_app_id()
    assert "password" not in str(section).lower()


def test_push_disabled_returns_none() -> None:
    os.environ["TWS_PUSH_ENABLE"] = "0"
    assert enroll_push_section("family.test") is None
