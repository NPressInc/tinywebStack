"""Cloudflare request shapes, with no network and no real token."""

from __future__ import annotations

import json

import httpx
import pytest

from tinyweb_controlplane.errors import ProviderError
from tinyweb_controlplane.hosts import TUNNEL_ORIGIN_SERVICE
from tinyweb_controlplane.providers import CloudflareProvider, DnsRecord, IngressRule, TunnelSpec


class Api:
    def __init__(self, *, fail_message: str = "") -> None:
        self.calls: list[tuple[str, str, dict | None]] = []
        self.fail_message = fail_message
        self.created = False
        self.ordered = False
        self.a_record_deleted = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content) if request.content else None
        self.calls.append((request.method, request.url.path, body))
        if self.fail_message:
            return httpx.Response(
                500,
                json={"success": False, "errors": [{"code": 1000, "message": self.fail_message}]},
            )
        path = request.url.path
        if path.endswith("/cfd_tunnel") and request.method == "GET":
            if not self.created:
                return httpx.Response(200, json={"success": True, "result": []})
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "result": [
                        {
                            "id": "tunnel-1",
                            "name": "tinyweb-smith-unitabc",
                            "account_tag": "account-1",
                        }
                    ],
                },
            )
        if path.endswith("/cfd_tunnel") and request.method == "POST":
            self.created = True
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "result": {
                        "id": "tunnel-1",
                        "name": "tinyweb-smith-unitabc",
                        "account_tag": "account-1",
                        "token": "issued-tunnel-token",
                        "credentials_file": {
                            "AccountTag": "account-1",
                            "TunnelID": "tunnel-1",
                            "TunnelName": "tinyweb-smith-unitabc",
                            "TunnelSecret": "issued-tunnel-secret",
                        },
                    },
                },
            )
        if path.endswith("/token") and request.method == "GET":
            return httpx.Response(200, json={"success": True, "result": "fetched-tunnel-token"})
        if path.endswith("/configurations") and request.method == "PUT":
            return httpx.Response(200, json={"success": True, "result": {}})
        if path.endswith("/dns_records") and request.method == "GET":
            if not self.a_record_deleted:
                return httpx.Response(
                    200,
                    json={
                        "success": True,
                        "result": [{"id": "rec-a", "type": "A", "name": "smith.tinyweb.win", "content": "203.0.113.9"}],
                    },
                )
            return httpx.Response(200, json={"success": True, "result": []})
        if path.endswith("/dns_records/rec-a") and request.method == "DELETE":
            self.a_record_deleted = True
            return httpx.Response(200, json={"success": True, "result": {"id": "rec-a"}})
        if path.endswith("/dns_records") and request.method == "POST":
            return httpx.Response(200, json={"success": True, "result": {"id": "rec-cname"}})
        if path.endswith("/ssl/certificate_packs") and request.method == "GET":
            if not self.ordered:
                return httpx.Response(200, json={"success": True, "result": []})
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "result": [
                        {
                            "id": "pack-1",
                            "type": "advanced",
                            "status": "pending_validation",
                            "hosts": ["tinyweb.win", "smith.tinyweb.win", "*.smith.tinyweb.win"],
                        }
                    ],
                },
            )
        if path.endswith("/ssl/certificate_packs/order") and request.method == "POST":
            self.ordered = True
            return httpx.Response(
                200,
                json={"success": True, "result": {"id": "pack-1", "status": "pending_validation"}},
            )
        if path.endswith("/acm/total_tls") and request.method == "POST":
            return httpx.Response(
                200,
                json={"success": True, "result": {"enabled": True, "certificate_authority": "lets_encrypt"}},
            )
        if path.endswith("/cfd_tunnel/missing") and request.method == "DELETE":
            return httpx.Response(404, json={"success": False, "errors": [{"code": 404, "message": "not found"}]})
        return httpx.Response(500, json={"success": False, "errors": [{"code": 1, "message": f"unexpected {request.method} {path}"}]})


def _provider(api: Api, **kwargs) -> CloudflareProvider:
    client = httpx.Client(
        transport=httpx.MockTransport(api),
        base_url="https://api.cloudflare.com/client/v4/",
    )
    return CloudflareProvider(
        account_id="account-1",
        zone_id="zone-1",
        api_token="test-api-token",
        base_domain="tinyweb.win",
        cert_method=kwargs.get("cert_method", "advanced"),
        cert_authority="lets_encrypt",
        client=client,
    )


def _spec() -> TunnelSpec:
    return TunnelSpec(
        name="tinyweb-smith-unitabc",
        rules=[
            IngressRule(
                hostname="smith.tinyweb.win",
                service=TUNNEL_ORIGIN_SERVICE,
                http_host_header="smith.tinyweb.win",
            ),
            IngressRule(
                hostname="matrix.smith.tinyweb.win",
                service=TUNNEL_ORIGIN_SERVICE,
                http_host_header="matrix.smith.tinyweb.win",
            ),
        ],
    )


def test_create_tunnel_is_remote_managed_and_idempotent() -> None:
    api = Api()
    provider = _provider(api)
    first = provider.create_tunnel(_spec())
    assert first.token == "issued-tunnel-token"
    assert first.tunnel_id == "tunnel-1"
    second = provider.create_tunnel(_spec())
    assert second.token == "fetched-tunnel-token"
    posts = [call for call in api.calls if call[0] == "POST" and call[1].endswith("/cfd_tunnel")]
    assert len(posts) == 1
    assert posts[0][2] == {"name": "tinyweb-smith-unitabc", "config_src": "cloudflare"}
    puts = [call for call in api.calls if call[1].endswith("/configurations")]
    assert len(puts) == 2
    ingress = puts[0][2]["config"]["ingress"]
    assert ingress[-1] == {"service": "http_status:404"}
    assert ingress[0]["originRequest"]["noTLSVerify"] is True
    assert ingress[0]["originRequest"]["httpHostHeader"] == "smith.tinyweb.win"
    assert all(rule.get("hostname") != "jellyfin.smith.tinyweb.win" for rule in ingress)
    assert "test-api-token" not in json.dumps(posts)


def test_cname_replaces_a_record_from_the_ddns_helper() -> None:
    api = Api()
    provider = _provider(api)
    provider.upsert_cname(
        DnsRecord(
            name="smith.tinyweb.win",
            type="CNAME",
            content="tunnel-1.cfargotunnel.com",
            proxied=True,
        )
    )
    methods = [(call[0], call[1]) for call in api.calls]
    assert any(method == "DELETE" and path.endswith("/dns_records/rec-a") for method, path in methods)
    post = next(call for call in api.calls if call[0] == "POST" and call[1].endswith("/dns_records"))
    assert post[2]["type"] == "CNAME"
    assert post[2]["proxied"] is True
    assert post[2]["content"] == "tunnel-1.cfargotunnel.com"
    with pytest.raises(ProviderError):
        provider.upsert_cname(
            DnsRecord(name="smith.tinyweb.win", type="A", content="203.0.113.9", proxied=False)
        )


def test_advanced_certificate_order_includes_apex_and_is_not_repeated() -> None:
    api = Api()
    provider = _provider(api)
    from tinyweb_controlplane.providers import CertRequest

    request = CertRequest(
        method="advanced_certificate_manager",
        hosts=["tinyweb.win", "smith.tinyweb.win", "*.smith.tinyweb.win"],
    )
    first = provider.ensure_edge_certificate(request)
    second = provider.ensure_edge_certificate(request)
    assert first.pack_id == "pack-1"
    assert first.ready is False
    assert second.pack_id == "pack-1"
    orders = [call for call in api.calls if call[1].endswith("/certificate_packs/order")]
    assert len(orders) == 1
    assert orders[0][2]["type"] == "advanced"
    assert orders[0][2]["hosts"][0] == "tinyweb.win"
    assert "*.smith.tinyweb.win" in orders[0][2]["hosts"]
    assert "test-api-token" not in json.dumps(orders[0][2])


def test_total_tls_enables_the_zone_setting() -> None:
    api = Api()
    provider = _provider(api)
    from tinyweb_controlplane.providers import CertRequest

    cert = provider.ensure_edge_certificate(
        CertRequest(method="total_tls", hosts=["matrix.smith.tinyweb.win"])
    )
    assert cert.method == "total_tls"
    assert cert.status == "enabled"
    assert cert.ready is False
    post = next(call for call in api.calls if call[1].endswith("/acm/total_tls"))
    assert post[2] == {"enabled": True, "certificate_authority": "lets_encrypt"}


def test_errors_do_not_echo_the_api_token_and_missing_tunnels_are_gone() -> None:
    token = "super-secret-token"
    api = Api(fail_message=f"bad {token}")
    client = httpx.Client(transport=httpx.MockTransport(api), base_url="https://api.cloudflare.com/client/v4/")
    provider = CloudflareProvider(
        account_id="account-1",
        zone_id="zone-1",
        api_token=token,
        base_domain="tinyweb.win",
        cert_method="advanced",
        cert_authority="lets_encrypt",
        client=client,
    )
    with pytest.raises(ProviderError) as exc:
        provider.create_tunnel(_spec())
    assert token not in str(exc.value)

    ok = Api()
    quiet = _provider(ok)
    quiet.delete_tunnel("missing")
