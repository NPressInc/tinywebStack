"""Jellyfin can be added or removed after the tunnel exists.

The fake provider must not report published: true. The setup code is not a credential.
"""

from __future__ import annotations

from tinyweb_controlplane.providers import FakeProvider

from support import claim, mint


def _issued(world, *, jellyfin: bool = False):
    unit = mint(world)
    claimed = claim(world, unit["setup_code"], "smith")
    assert claimed.status_code == 200, claimed.text
    token = claimed.json()["claim_token"]
    issued = world.client.post(
        "/v1/tunnels",
        headers={"Authorization": f"Bearer {token}"},
        json={"jellyfin": jellyfin},
    )
    assert issued.status_code == 200, issued.text
    return unit, token, issued.json()


def _hosts(world, token: str, *, jellyfin: bool):
    return world.client.post(
        "/v1/tunnels/hosts",
        headers={"Authorization": f"Bearer {token}"},
        json={"jellyfin": jellyfin},
    )


def test_post_setup_claim_token_adds_and_removes_jellyfin_without_publishing(world) -> None:
    unit, token, issued = _issued(world, jellyfin=False)
    names = [row["name"] for row in issued["dns"]]
    assert "jellyfin.smith.tinyweb.win" not in names
    assert issued["published"] is False
    assert world.provider.create_calls == 1

    done = world.client.post("/v1/setup/complete", headers={"Authorization": f"Bearer {token}"})
    assert done.status_code == 200, done.text

    as_code = _hosts(world, unit["setup_code"], jellyfin=True)
    assert as_code.status_code == 401
    assert "jellyfin.smith.tinyweb.win" not in world.provider.records

    operator = world.client.post(
        "/v1/tunnels/hosts",
        headers={"Authorization": "Bearer operator-test-token"},
        json={"jellyfin": True},
    )
    assert operator.status_code == 403

    added = _hosts(world, token, jellyfin=True)
    assert added.status_code == 200, added.text
    body = added.json()
    assert body["status"] == "updated"
    assert body["published"] is False
    assert body["provider"] == "fake"
    assert body["tunnel"]["tunnel_id"] == issued["tunnel"]["tunnel_id"]
    assert world.provider.create_calls == 1
    row = next(item for item in body["dns"] if item["name"] == "jellyfin.smith.tinyweb.win")
    assert row["type"] == "CNAME"
    assert row["proxied"] is True
    assert row["applied"] is False
    assert row["content"].endswith(".cfargotunnel.com")
    assert "immich" not in added.text
    rules = next(iter(world.provider.tunnels.values()))["rules"]
    assert any(rule.hostname == "jellyfin.smith.tinyweb.win" for rule in rules)
    assert "matrix.smith.tinyweb.win" in world.provider.records
    assert world.provider.records["jellyfin.smith.tinyweb.win"].proxied is True

    again = _hosts(world, token, jellyfin=True)
    assert again.status_code == 200, again.text
    assert again.json()["published"] is False
    assert sum(1 for item in again.json()["dns"] if item["name"].startswith("jellyfin.")) == 1
    assert world.provider.create_calls == 1

    replay = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {token}"}, json={})
    assert replay.status_code == 200, replay.text
    assert replay.json()["replayed"] is True
    assert replay.json()["published"] is False
    assert "jellyfin.smith.tinyweb.win" in [item["name"] for item in replay.json()["dns"]]
    assert world.provider.create_calls == 1

    status = world.client.get("/v1/families/smith", headers={"Authorization": f"Bearer {token}"})
    assert status.status_code == 200
    assert status.json()["published"] is False
    assert "jellyfin.smith.tinyweb.win" in status.json()["dns_hostnames"]
    assert body["tunnel"]["token"] not in status.text
    assert unit["setup_code"] not in status.text

    removed = _hosts(world, token, jellyfin=False)
    assert removed.status_code == 200, removed.text
    assert removed.json()["published"] is False
    assert "jellyfin.smith.tinyweb.win" not in [item["name"] for item in removed.json()["dns"]]
    assert "matrix.smith.tinyweb.win" in [item["name"] for item in removed.json()["dns"]]
    assert "jellyfin.smith.tinyweb.win" not in world.provider.records
    assert "jellyfin.smith.tinyweb.win" in world.provider.deleted_names
    rules = next(iter(world.provider.tunnels.values()))["rules"]
    assert all(rule.hostname != "jellyfin.smith.tinyweb.win" for rule in rules)
    assert world.provider.create_calls == 1

    gone = _hosts(world, token, jellyfin=False)
    assert gone.status_code == 200
    assert gone.json()["published"] is False


def test_hosts_rejects_immich_and_a_missing_tunnel(world) -> None:
    unit = mint(world)
    claimed = claim(world, unit["setup_code"], "smith")
    token = claimed.json()["claim_token"]
    missing = _hosts(world, token, jellyfin=True)
    assert missing.status_code == 409
    assert missing.json()["error"] == "tunnel_not_issued"
    assert world.provider.records == {}
    assert world.provider.create_calls == 0

    _issued_token = world.client.post(
        "/v1/tunnels",
        headers={"Authorization": f"Bearer {token}"},
        json={},
    )
    assert _issued_token.status_code == 200
    immich = world.client.post(
        "/v1/tunnels/hosts",
        headers={"Authorization": f"Bearer {token}"},
        json={"jellyfin": True, "immich": True},
    )
    assert immich.status_code == 400
    assert immich.json()["error"] == "invalid_host"
    assert "immich" not in [row["name"] for row in world.client.post(
        "/v1/tunnels",
        headers={"Authorization": f"Bearer {token}"},
        json={},
    ).json()["dns"]]
    blank = world.client.post(
        "/v1/tunnels/hosts",
        headers={"Authorization": f"Bearer {token}"},
        json={},
    )
    assert blank.status_code == 400
    assert blank.json()["error"] == "invalid_body"


def test_failed_ingress_update_does_not_keep_the_cname(world) -> None:
    _unit, token, issued = _issued(world, jellyfin=False)
    world.provider.fail_ingress = True
    failed = _hosts(world, token, jellyfin=True)
    assert failed.status_code == 502
    assert failed.json()["error"] == "provider_failed"
    assert "No public hostname was published." in failed.json()["detail"]
    assert "token" not in failed.json()
    assert "jellyfin.smith.tinyweb.win" not in world.provider.records
    replay = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {token}"}, json={})
    assert "jellyfin.smith.tinyweb.win" not in [item["name"] for item in replay.json()["dns"]]
    assert replay.json()["published"] is False
    assert replay.json()["tunnel"]["tunnel_id"] == issued["tunnel"]["tunnel_id"]


def test_fake_provider_cannot_report_published_true_from_a_stored_flag(world) -> None:
    _unit, token, issued = _issued(world, jellyfin=False)
    store = world.app.state.store
    store._conn.execute("UPDATE tunnels SET published = 1")
    added = _hosts(world, token, jellyfin=True)
    assert added.status_code == 200, added.text
    assert added.json()["published"] is False
    assert all(item["applied"] is False for item in added.json()["dns"])
    assert world.provider.publishes is False
    assert isinstance(world.provider, FakeProvider)
    status = world.client.get("/v1/families/smith", headers={"Authorization": f"Bearer {token}"})
    assert status.json()["published"] is False
    assert issued["tunnel"]["token"] not in status.text
