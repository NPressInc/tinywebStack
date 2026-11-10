"""One-time factory setup code. It works until setup is marked complete."""

from __future__ import annotations

import logging
import sqlite3

from tinyweb_controlplane.redact import SecretLogFilter

from support import claim, mint


def test_unknown_code_is_rejected_and_plaintext_is_not_stored(world) -> None:
    missing = claim(world, "not-a-real-code", "smith")
    assert missing.status_code == 401
    assert missing.json()["error"] == "unknown_setup_code"

    unit = mint(world)
    raw = world.db.read_bytes()
    assert unit["setup_code"].encode() not in raw
    assert b"operator-test-token" not in raw


def test_claim_replays_until_complete_then_cannot_take_over(world) -> None:
    unit = mint(world)
    parent_password = "parent-chosen-password"
    first = world.client.post(
        "/v1/setup/claim",
        json={"setup_code": unit["setup_code"], "slug": "smith", "password": parent_password},
    )
    assert first.status_code == 200, first.text
    token = first.json()["claim_token"]
    assert "tunnel" not in first.json()

    replay = claim(world, unit["setup_code"], "smith")
    assert replay.status_code == 200
    assert replay.json()["replayed"] is True
    assert replay.json()["claim_token"] == token

    moved = claim(world, unit["setup_code"], "other")
    assert moved.status_code == 409
    assert moved.json()["error"] == "slug_already_reserved"
    assert moved.json()["slug"] == "smith"
    assert "claim_token" not in moved.json()

    query = world.client.post("/v1/setup/claim?code=" + unit["setup_code"], json={"setup_code": unit["setup_code"], "slug": "smith"})
    assert query.status_code == 400
    assert query.json()["error"] == "secret_in_query"

    done = world.client.post("/v1/setup/complete", headers={"Authorization": f"Bearer {token}"})
    assert done.status_code == 200, done.text
    assert done.json()["status"] == "complete"

    again = world.client.post("/v1/setup/complete", headers={"Authorization": f"Bearer {token}"})
    assert again.status_code == 200
    assert again.json()["replayed"] is True

    takeover = claim(world, unit["setup_code"], "smith")
    assert takeover.status_code == 409
    assert takeover.json()["error"] == "setup_already_complete"
    assert "claim_token" not in takeover.json()
    assert takeover.json()["slug"] == "smith"

    operator = world.client.post(
        "/v1/setup/complete",
        headers={"Authorization": "Bearer operator-test-token"},
    )
    assert operator.status_code == 403

    with sqlite3.connect(world.db) as conn:
        pending, code_hash = conn.execute(
            "SELECT claim_token_pending, setup_code_hash FROM units"
        ).fetchone()
    assert pending is None
    assert code_hash
    assert token.encode() not in world.db.read_bytes()
    assert parent_password.encode() not in world.db.read_bytes()
    assert unit["setup_code"].encode() not in world.db.read_bytes()


def test_log_line_redacts_setup_code_and_tunnel_token() -> None:
    record = logging.LogRecord(
        name="tinyweb_controlplane",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg='body {"setup_code": "lid-secret", "token": "tunnel-secret"} Bearer lid-secret TUNNEL_TOKEN=tunnel-secret',
        args=(),
        exc_info=None,
    )
    assert SecretLogFilter().filter(record) is True
    rendered = record.getMessage()
    assert "lid-secret" not in rendered
    assert "tunnel-secret" not in rendered
    assert "REDACTED" in rendered


def test_operator_mint_requires_the_operator_token(world) -> None:
    missing = world.client.post("/v1/operator/units")
    assert missing.status_code == 401
    wrong = world.client.post("/v1/operator/units", headers={"Authorization": "Bearer no"})
    assert wrong.status_code == 401
