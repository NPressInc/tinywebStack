"""Pusher policy helpers and Synapse event_id_only shape."""

from __future__ import annotations

from tinywebstack_family.pusher_policy import (
    REQUIRED_FORMAT,
    normalize_http_pusher_data,
    synapse_event_id_only_content,
    validate_http_pusher_registration,
)


def test_normalize_forces_event_id_only() -> None:
    data = normalize_http_pusher_data({"url": "http://127.0.0.1/x", "format": "full"})
    assert data["format"] == REQUIRED_FORMAT


def test_validate_rejects_wrong_format() -> None:
    ok, _ = validate_http_pusher_registration(
        "app",
        "key",
        {"url": "http://127.0.0.1/n", "format": "full"},
    )
    assert ok is False


def test_validate_accepts_event_id_only() -> None:
    ok, msg = validate_http_pusher_registration(
        "win.tinyweb.tinyweb.android",
        "tw-topic",
        {"url": "http://127.0.0.1:8090/_matrix/push/v1/notify", "format": "event_id_only"},
    )
    assert ok is True
    assert msg == ""


def test_synapse_event_id_only_has_no_body() -> None:
    content = synapse_event_id_only_content("$e", "!r:hs", 3)
    assert content["event_id"] == "$e"
    assert content["room_id"] == "!r:hs"
    assert "body" not in content
    assert "sender" not in content
