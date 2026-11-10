"""The existing DDNS helper posts here. Tunnel DNS is not replaced with A records."""

from __future__ import annotations

from support import claim, mint


def test_webhook_matches_the_ddns_script_and_does_not_write_a_records(world) -> None:
    unit = mint(world)
    assert claim(world, unit["setup_code"], "smith").status_code == 200
    issued = world.client.post(
        "/v1/tunnels",
        headers={"Authorization": f"Bearer {claim(world, unit['setup_code'], 'smith').json()['claim_token']}"},
        json={},
    )
    assert issued.status_code == 200
    before = dict(world.provider.records)

    # Same keys as scripts/vm/tinyweb-subdomain-ddns.sh ddns_update_webhook.
    response = world.client.post(
        "/v1/ddns",
        json={
            "token": "ddns-test-token",
            "domain": "smith.tinyweb.win",
            "wildcard": "*.smith.tinyweb.win",
            "ipv4": "203.0.113.10",
            "ipv6": "",
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body == {
        "ok": True,
        "status": "tunnel-managed",
        "changed": False,
        "domain": "smith.tinyweb.win",
        "records": "cname",
    }
    assert "203.0.113.10" not in response.text
    assert "ddns-test-token" not in response.text
    assert world.provider.records == before
    assert all(record.type == "CNAME" for record in world.provider.records.values())
    assert "*.smith.tinyweb.win" not in world.provider.records


def test_webhook_rejects_bad_tokens_and_unmanaged_names(world) -> None:
    missing = world.client.post(
        "/v1/ddns",
        json={"token": "nope", "domain": "smith.tinyweb.win", "wildcard": "*.smith.tinyweb.win", "ipv4": "203.0.113.10", "ipv6": ""},
    )
    assert missing.status_code == 401
    unknown = world.client.post(
        "/v1/ddns",
        json={"token": "ddns-test-token", "domain": "nobody.tinyweb.win", "wildcard": "", "ipv4": "203.0.113.10", "ipv6": ""},
    )
    assert unknown.status_code == 404
    assert unknown.json()["error"] == "not_managed"
    assert world.provider.records == {}


def test_reserved_name_is_tunnel_managed_before_credentials_exist(world) -> None:
    unit = mint(world)
    assert claim(world, unit["setup_code"], "smith").status_code == 200
    response = world.client.post(
        "/v1/ddns",
        json={"token": "ddns-test-token", "domain": "smith.tinyweb.win", "wildcard": "*.smith.tinyweb.win", "ipv4": "198.51.100.4", "ipv6": ""},
    )
    assert response.status_code == 200
    assert response.json()["changed"] is False
    assert world.provider.create_calls == 0
    assert world.provider.records == {}
