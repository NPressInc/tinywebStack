"""Tunnel credential handoff. The fake provider must not look published."""

from __future__ import annotations

from tinyweb_controlplane.app import create_app
from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.providers import FakeProvider

from support import claim, mint


def _ready(world, *, jellyfin: bool = False):
    unit = mint(world)
    claimed = claim(world, unit["setup_code"], "smith")
    assert claimed.status_code == 200, claimed.text
    token = claimed.json()["claim_token"]
    issued = world.client.post(
        "/v1/tunnels",
        headers={"Authorization": f"Bearer {token}"},
        json={"jellyfin": jellyfin},
    )
    return token, issued


def test_handoff_is_retryable_and_does_not_publish_from_the_fake_provider(world) -> None:
    naked = world.client.post("/v1/tunnels", json={})
    assert naked.status_code == 401

    token, issued = _ready(world, jellyfin=True)
    assert issued.status_code == 200, issued.text
    body = issued.json()
    assert body["published"] is False
    assert body["provider"] == "fake"
    assert body["edge_certificate_ready"] is False
    assert body["replayed"] is False
    assert body["tunnel"]["token"].startswith("fake-tunnel-token-")
    assert body["origin_service"] == "https://127.0.0.1:443"
    names = [row["name"] for row in body["dns"]]
    assert "smith.tinyweb.win" in names
    assert "matrix.smith.tinyweb.win" in names
    assert "owntracks.smith.tinyweb.win" in names
    assert all(row["type"] == "CNAME" and row["proxied"] is True and row["applied"] is False for row in body["dns"])
    assert all(row["content"].endswith(".cfargotunnel.com") for row in body["dns"])
    assert "jellyfin.smith.tinyweb.win" in names
    assert body["excluded_from_proxy"] == []
    jellyfin_row = next(row for row in body["dns"] if row["name"] == "jellyfin.smith.tinyweb.win")
    assert jellyfin_row["proxied"] is True
    assert jellyfin_row["type"] == "CNAME"
    assert jellyfin_row["applied"] is False
    assert body["certificate"]["method"] == "advanced_certificate_manager"
    assert body["certificate"]["hosts"] == [
        "tinyweb.win",
        "smith.tinyweb.win",
        "*.smith.tinyweb.win",
    ]
    assert "Universal SSL" in body["certificate"]["note"]
    assert world.provider.create_calls == 1

    rules = next(iter(world.provider.tunnels.values()))["rules"]
    assert any(rule.hostname == "jellyfin.smith.tinyweb.win" for rule in rules)

    retry = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {token}"}, json={})
    assert retry.status_code == 200
    assert retry.json()["replayed"] is True
    assert retry.json()["tunnel"]["tunnel_id"] == body["tunnel"]["tunnel_id"]
    assert retry.json()["published"] is False
    assert world.provider.create_calls == 1

    setup_code = mint(world)["setup_code"]
    as_code = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {setup_code}"}, json={})
    assert as_code.status_code == 401

    status = world.client.get("/v1/families/smith", headers={"Authorization": f"Bearer {token}"})
    assert status.status_code == 200
    text = status.text
    assert body["tunnel"]["token"] not in text
    assert "fake-tunnel-secret" not in text
    assert status.json()["published"] is False
    assert status.json()["tunnel"]["tunnel_id"] == body["tunnel"]["tunnel_id"]


def test_setup_code_cannot_reclaim_after_revoke(world) -> None:
    unit = mint(world)
    token = claim(world, unit["setup_code"], "smith").json()["claim_token"]
    first = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {token}"}, json={})
    assert first.status_code == 200
    first_id = first.json()["tunnel"]["tunnel_id"]

    done = world.client.post("/v1/setup/complete", headers={"Authorization": f"Bearer {token}"})
    assert done.status_code == 200
    blocked = claim(world, unit["setup_code"], "smith")
    assert blocked.status_code == 409
    assert blocked.json()["error"] == "setup_already_complete"

    revoked = world.client.post(
        "/v1/tunnels/revoke",
        headers={"Authorization": f"Bearer {token}"},
        json={"slug": "smith"},
    )
    assert revoked.status_code == 200, revoked.text
    assert revoked.json()["status"] == "revoked"
    assert first_id in world.provider.deleted_tunnels
    assert "smith.tinyweb.win" not in world.provider.records

    still_blocked = claim(world, unit["setup_code"], "smith")
    assert still_blocked.status_code == 409
    assert "claim_token" not in still_blocked.json()

    other = mint(world)
    assert claim(world, other["setup_code"], "smith").status_code == 409

    reissued = world.client.post("/v1/tunnels", headers={"Authorization": f"Bearer {token}"}, json={})
    assert reissued.status_code == 200, reissued.text
    assert reissued.json()["tunnel"]["tunnel_id"] != first_id
    assert reissued.json()["published"] is False
    assert world.provider.create_calls == 2


def test_provider_failure_does_not_leave_a_published_tunnel(world) -> None:
    world.provider.fail_certificate = True
    token, issued = _ready(world)
    assert issued.status_code == 502
    assert issued.json()["error"] == "provider_failed"
    assert "No public hostname was published." in issued.json()["detail"]
    assert "token" not in issued.json()
    assert world.provider.records == {}
    assert world.provider.deleted_tunnels
    status = world.client.get("/v1/families/smith", headers={"Authorization": f"Bearer {token}"})
    assert status.json()["tunnel"] is None
    assert status.json()["published"] is False


def test_missing_cloudflare_secrets_do_not_invent_a_hostname(tmp_path) -> None:
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token="operator-test-token",
        provider_name="cloudflare",
        cf_api_token="",
        cf_account_id="",
        cf_zone_id="",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    app = create_app(settings)
    with __import__("fastapi.testclient", fromlist=["TestClient"]).TestClient(app) as client:
        minted = client.post("/v1/operator/units", headers={"Authorization": "Bearer operator-test-token"})
        assert minted.status_code == 201
        claimed = client.post(
            "/v1/setup/claim",
            json={"setup_code": minted.json()["setup_code"], "slug": "smith"},
        )
        issued = client.post(
            "/v1/tunnels",
            headers={"Authorization": f"Bearer {claimed.json()['claim_token']}"},
            json={},
        )
    assert issued.status_code == 503
    body = issued.json()
    assert body["error"] == "cloudflare_not_configured"
    assert "CF_API_TOKEN" in body["detail"]
    assert "CF_ACCOUNT_ID" in body["detail"]
    assert "CF_ZONE_ID" in body["detail"]
    assert "No public hostname was published." in body["detail"]
    assert "published" not in body
    assert "tunnel" not in body


def test_routes_do_not_proxy_family_traffic(world) -> None:
    paths = " ".join(getattr(route, "path", "") for route in world.app.routes)
    for word in ("proxy", "matrix", "chat", "calendar", "jellyfin", "upload", "synapse"):
        assert word not in paths
    health = world.client.get("/v1/health")
    assert health.status_code == 200
    assert health.json()["service"] == "tinyweb-control-plane"
    assert health.json()["provider"] == "fake"


def test_total_tls_requests_coverage_for_proxied_nested_names(tmp_path) -> None:
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token="operator-test-token",
        provider_name="fake",
        edge_cert_method="total_tls",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    provider = FakeProvider()
    app = create_app(settings, provider=provider)
    from fastapi.testclient import TestClient

    with TestClient(app) as client:
        minted = client.post("/v1/operator/units", headers={"Authorization": "Bearer operator-test-token"})
        claimed = client.post(
            "/v1/setup/claim",
            json={"setup_code": minted.json()["setup_code"], "slug": "smith"},
        )
        issued = client.post(
            "/v1/tunnels",
            headers={"Authorization": f"Bearer {claimed.json()['claim_token']}"},
            json={"jellyfin": True},
        )
    assert issued.status_code == 200, issued.text
    hosts = issued.json()["certificate"]["hosts"]
    assert issued.json()["certificate"]["method"] == "total_tls"
    assert "matrix.smith.tinyweb.win" in hosts
    assert "jellyfin.smith.tinyweb.win" in hosts
    assert "immich" not in " ".join(hosts)
    assert issued.json()["published"] is False


def test_replay_refreshes_a_pending_edge_certificate(tmp_path) -> None:
    """A publishing provider can report the certificate on a later read.

    The default fake provider never enters this path.
    """
    from tinyweb_controlplane.providers import EdgeCertificate, IssuedTunnel

    class PendingThenReady:
        publishes = True
        name = "cloudflare"

        def __init__(self) -> None:
            self.cert_calls = 0
            self.create_calls = 0

        def create_tunnel(self, spec):
            self.create_calls += 1
            return IssuedTunnel(
                tunnel_id="00000000-0000-4000-8000-0000000000aa",
                account_tag="account",
                token="live-tunnel-token-example",
                credentials_file={"TunnelID": "00000000-0000-4000-8000-0000000000aa"},
                name=spec.name,
            )

        def delete_tunnel(self, tunnel_id: str) -> None:
            return None

        def upsert_cname(self, record) -> None:
            return None

        def delete_cname(self, name: str) -> None:
            return None

        def ensure_edge_certificate(self, request):
            self.cert_calls += 1
            ready = self.cert_calls >= 2
            return EdgeCertificate(
                method=request.method,
                hosts=list(request.hosts),
                status="active" if ready else "pending_validation",
                pack_id="pack",
                ready=ready,
            )

    provider = PendingThenReady()
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token="operator-test-token",
        provider_name="fake",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    app = create_app(settings, provider=provider)
    from fastapi.testclient import TestClient

    with TestClient(app) as client:
        minted = client.post(
            "/v1/operator/units",
            headers={"Authorization": "Bearer operator-test-token"},
        ).json()
        claimed = client.post(
            "/v1/setup/claim",
            json={"setup_code": minted["setup_code"], "slug": "smith"},
        ).json()
        headers = {"Authorization": f"Bearer {claimed['claim_token']}"}
        first = client.post("/v1/tunnels", headers=headers, json={})
        second = client.post("/v1/tunnels", headers=headers, json={})
    assert first.status_code == 200, first.text
    assert first.json()["published"] is True
    assert first.json()["edge_certificate_ready"] is False
    assert second.status_code == 200, second.text
    assert second.json()["replayed"] is True
    assert second.json()["published"] is True
    assert second.json()["edge_certificate_ready"] is True
    assert second.json()["certificate"]["ready"] is True
    assert provider.create_calls == 1
    assert provider.cert_calls == 2
