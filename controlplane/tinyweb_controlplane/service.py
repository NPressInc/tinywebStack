"""Slug reservation, one-time setup claim, and tunnel credential handoff."""

from __future__ import annotations

import json
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from urllib.parse import quote

from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.errors import ApiError, ProviderError, ProviderNotConfigured
from tinyweb_controlplane.hosts import (
    TUNNEL_ORIGIN_SERVICE,
    advanced_certificate_hosts,
    node_all_domains,
    split_proxy_hosts,
)
from tinyweb_controlplane.providers import (
    CertRequest,
    ControlProvider,
    DnsRecord,
    IngressRule,
    IssuedTunnel,
    TunnelSpec,
)
from tinyweb_controlplane.security import hash_secret, secrets_equal
from tinyweb_controlplane.slugs import family_domain, validate_slug
from tinyweb_controlplane.store import Store

LOCATION_APPS = {"owntracks", "traccar"}
EVENTS_APPS = {"mobilizon", "none"}


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


@dataclass
class TunnelOptions:
    location_app: str = "owntracks"
    events_app: str = "mobilizon"
    push: bool = True
    jellyfin: bool = False

    def validated(self) -> TunnelOptions:
        location = self.location_app.strip().lower()
        events = self.events_app.strip().lower()
        if location not in LOCATION_APPS:
            raise ApiError(400, "invalid_location_app", "location_app must be owntracks or traccar.")
        if events not in EVENTS_APPS:
            raise ApiError(400, "invalid_events_app", "events_app must be mobilizon or none.")
        return TunnelOptions(
            location_app=location,
            events_app=events,
            push=bool(self.push),
            jellyfin=bool(self.jellyfin),
        )


class Service:
    def __init__(self, settings: Settings, store: Store, provider: ControlProvider) -> None:
        self.settings = settings
        self.store = store
        self.provider = provider

    def mint_unit(self) -> dict[str, Any]:
        setup_code = secrets.token_urlsafe(32)
        unit_id = "unit" + secrets.token_hex(6)
        self.store.create_unit(
            unit_id=unit_id,
            setup_code_hash=hash_secret(setup_code),
            created_at=_now(),
        )
        encoded = quote(setup_code, safe="")
        origin = self.settings.public_origin
        return {
            "unit_id": unit_id,
            "setup_code": setup_code,
            "setup_url": f"{origin}/setup#code={encoded}",
            "setup_app_url": f"tinyweb://setup#code={encoded}",
        }

    def check_slug(self, raw: str) -> dict[str, Any]:
        try:
            slug = validate_slug(raw)
        except ApiError as exc:
            return {
                "slug": raw.strip().lower()[:63],
                "domain": None,
                "available": False,
                "reason": exc.code,
                "detail": exc.detail,
            }
        domain = family_domain(slug, self.settings.base_domain)
        row = self.store.slug_row(slug)
        if row is not None:
            return {
                "slug": slug,
                "domain": domain,
                "available": False,
                "reason": "slug_taken",
                "detail": f"{slug} is already reserved.",
            }
        return {
            "slug": slug,
            "domain": domain,
            "available": True,
            "reason": None,
            "detail": None,
        }

    def claim(self, setup_code: str, raw_slug: str) -> dict[str, Any]:
        slug = validate_slug(raw_slug)
        if not setup_code or not setup_code.strip():
            raise ApiError(401, "unknown_setup_code", "Setup code was not recognized.")
        domain = family_domain(slug, self.settings.base_domain)
        claim_token = secrets.token_urlsafe(32)
        result = self.store.claim(
            setup_code_hash=hash_secret(setup_code.strip()),
            slug=slug,
            domain=domain,
            new_claim_token=claim_token,
            new_claim_token_hash=hash_secret(claim_token),
            now=_now(),
        )
        kind = result["kind"]
        if kind == "unknown_code":
            raise ApiError(401, "unknown_setup_code", "Setup code was not recognized.")
        if kind == "slug_taken":
            raise ApiError(409, "slug_taken", f"{slug} is already reserved.")
        if kind == "already_complete":
            raise ApiError(
                409,
                "setup_already_complete",
                "This setup code was already used. It cannot take over the box. Reclaiming needs the parent.",
                slug=result.get("slug"),
                domain=family_domain(result["slug"], self.settings.base_domain) if result.get("slug") else None,
            )
        if kind == "slug_mismatch":
            bound = result["slug"]
            raise ApiError(
                409,
                "slug_already_reserved",
                f"This box is already reserving {bound}. The setup code cannot move it to another name.",
                slug=bound,
                domain=family_domain(bound, self.settings.base_domain),
            )
        if kind == "claim_token_unavailable":
            raise ApiError(
                409,
                "claim_token_unavailable",
                "Setup is in progress on the box, and this service no longer has a copy of the claim token.",
                slug=result.get("slug"),
            )
        if kind not in {"created", "replay"}:
            raise ApiError(500, "claim_failed", "Could not reserve the family name.")
        return {
            "status": "claimed",
            "replayed": kind == "replay",
            "unit_id": result["unit_id"],
            "slug": result["slug"],
            "domain": family_domain(result["slug"], self.settings.base_domain),
            "claim_token": result["claim_token"],
        }

    def complete(self, claim_token: str) -> dict[str, Any]:
        unit = self._unit_for_claim(claim_token)
        unit_id = str(unit["unit_id"])
        slug = str(unit["slug"])
        result = self.store.complete(hash_secret(claim_token), _now())
        if result["kind"] == "unknown_token":
            raise ApiError(401, "invalid_claim_token", "Claim token was not recognized.")
        return {
            "status": "complete",
            "replayed": result["kind"] == "already_complete",
            "unit_id": unit_id,
            "slug": slug,
            "domain": family_domain(slug, self.settings.base_domain),
        }

    def issue_tunnel(self, claim_token: str, options: TunnelOptions) -> dict[str, Any]:
        opts = options.validated()
        unit = self._unit_for_claim(claim_token)
        unit_id = str(unit["unit_id"])
        slug = str(unit["slug"])
        existing = self.store.active_tunnel(unit_id)
        if existing is not None:
            return self._handoff_from_row(existing, replayed=True)
        domain = family_domain(slug, self.settings.base_domain)
        try:
            hostnames = node_all_domains(
                domain,
                location_app=opts.location_app,
                events_app=opts.events_app,
                push=opts.push,
                jellyfin=opts.jellyfin,
            )
        except RuntimeError as exc:
            raise ApiError(500, "hostname_list_failed", str(exc)) from None
        proxied, excluded = split_proxy_hosts(hostnames)
        if domain not in proxied:
            proxied.insert(0, domain)
        rules = [
            IngressRule(
                hostname=host,
                service=TUNNEL_ORIGIN_SERVICE,
                http_host_header=host,
            )
            for host in proxied
        ]
        spec = TunnelSpec(name=f"tinyweb-{slug}-{unit_id}", rules=rules)
        cert_method = (
            "total_tls" if self.settings.edge_cert_method == "total_tls" else "advanced_certificate_manager"
        )
        if self.settings.edge_cert_method == "total_tls":
            cert_hosts = list(proxied)
        else:
            cert_hosts = advanced_certificate_hosts(self.settings.base_domain, domain)
        issued: IssuedTunnel | None = None
        applied: list[str] = []
        try:
            issued = self.provider.create_tunnel(spec)
            records: list[DnsRecord] = []
            for host in proxied:
                record = DnsRecord(
                    name=host,
                    type="CNAME",
                    content=f"{issued.tunnel_id}.cfargotunnel.com",
                    proxied=True,
                )
                self.provider.upsert_cname(record)
                applied.append(host)
                records.append(record)
            certificate = self.provider.ensure_edge_certificate(
                CertRequest(method=cert_method, hosts=cert_hosts)
            )
        except ProviderNotConfigured as exc:
            self._rollback(issued, applied)
            raise ApiError(
                503,
                "cloudflare_not_configured",
                "Set " + ", ".join(exc.missing) + " on the control plane. No public hostname was published.",
            ) from None
        except ProviderError as exc:
            self._rollback(issued, applied)
            raise ApiError(
                502,
                "provider_failed",
                f"{exc} No public hostname was published.",
            ) from None
        except Exception:
            self._rollback(issued, applied)
            raise
        assert issued is not None
        published = bool(self.provider.publishes)
        dns = [record.as_dict(applied=published) for record in records]
        cert_dict = certificate.as_dict()
        try:
            self.store.save_tunnel(
                unit_id=unit_id,
                slug=slug,
                cf_tunnel_id=issued.tunnel_id,
                account_tag=issued.account_tag,
                token=issued.token,
                credentials_json=json.dumps(issued.credentials_file),
                published=published,
                provider=self.provider.name,
                dns_json=json.dumps(dns),
                cert_json=json.dumps(cert_dict),
                excluded_json=json.dumps(excluded),
                created_at=_now(),
            )
        except Exception:
            self._rollback(issued, applied)
            raise
        saved = self.store.active_tunnel(unit_id)
        if saved is None:
            raise ApiError(
                500,
                "tunnel_not_stored",
                "Tunnel credentials were not stored. No public hostname was published.",
            )
        return self._handoff_from_row(saved, replayed=False)

    def revoke(self, *, unit_id: str) -> dict[str, Any]:
        row = self.store.active_tunnel(unit_id)
        if row is None:
            unit_slug = self._slug_for_unit(unit_id)
            return {
                "status": "no_active_tunnel",
                "slug": unit_slug,
                "domain": family_domain(unit_slug, self.settings.base_domain) if unit_slug else None,
            }
        dns = json.loads(row["dns_json"])
        names = [item["name"] for item in dns if isinstance(item, dict) and item.get("name")]
        try:
            for name in names:
                self.provider.delete_cname(name)
            self.provider.delete_tunnel(row["cf_tunnel_id"])
        except ProviderNotConfigured as exc:
            raise ApiError(
                503,
                "cloudflare_not_configured",
                "Set " + ", ".join(exc.missing) + " on the control plane before revoking a live tunnel.",
            ) from None
        except ProviderError as exc:
            raise ApiError(502, "provider_failed", str(exc)) from None
        self.store.revoke_active(unit_id, _now())
        return {
            "status": "revoked",
            "slug": row["slug"],
            "domain": family_domain(row["slug"], self.settings.base_domain),
            "tunnel_id": row["cf_tunnel_id"],
        }

    def family_status(self, slug: str) -> dict[str, Any]:
        slug = validate_slug(slug)
        reserved = self.store.slug_row(slug)
        if reserved is None:
            raise ApiError(404, "unknown_family", f"{slug} is not reserved.")
        domain = family_domain(slug, self.settings.base_domain)
        tunnel = self.store.active_tunnel(reserved["unit_id"])
        if tunnel is None:
            return {
                "slug": slug,
                "domain": domain,
                "setup_complete": self._setup_complete(reserved["unit_id"]),
                "tunnel": None,
                "published": False,
                "edge_certificate_ready": False,
                "dns_hostnames": [],
                "excluded_from_proxy": [],
            }
        cert = json.loads(tunnel["cert_json"])
        dns = json.loads(tunnel["dns_json"])
        return {
            "slug": slug,
            "domain": domain,
            "setup_complete": self._setup_complete(reserved["unit_id"]),
            "tunnel": {"tunnel_id": tunnel["cf_tunnel_id"], "status": tunnel["status"]},
            "published": bool(tunnel["published"]),
            "edge_certificate_ready": bool(cert.get("ready")),
            "dns_hostnames": [item["name"] for item in dns],
            "excluded_from_proxy": json.loads(tunnel["excluded_json"]),
        }

    def ddns(self, *, token: str, domain: str) -> dict[str, Any]:
        expected = self.settings.ddns_token
        if not expected:
            raise ApiError(
                503,
                "ddns_not_configured",
                "Set TWS_DDNS_TOKEN on the control plane. This endpoint does not write A records.",
            )
        if not secrets_equal(token, expected):
            raise ApiError(401, "unauthorized", "DDNS token rejected.")
        name = (domain or "").strip().lower().rstrip(".")
        base = self.settings.base_domain
        suffix = "." + base
        if not name.endswith(suffix):
            raise ApiError(
                404,
                "not_managed",
                "This control plane does not write A records. Reserve the family here and use a tunnel.",
            )
        slug = name[: -len(suffix)]
        if self.store.slug_row(slug) is None:
            raise ApiError(
                404,
                "not_managed",
                "This control plane does not write A records. Reserve the family here and use a tunnel.",
            )
        return {
            "ok": True,
            "status": "tunnel-managed",
            "changed": False,
            "domain": name,
            "records": "cname",
        }

    def _rollback(self, issued: IssuedTunnel | None, names: list[str]) -> None:
        for name in names:
            try:
                self.provider.delete_cname(name)
            except (ProviderError, ProviderNotConfigured):
                continue
        if issued is not None:
            try:
                self.provider.delete_tunnel(issued.tunnel_id)
            except (ProviderError, ProviderNotConfigured):
                return

    def _unit_for_claim(self, claim_token: str):
        if not claim_token:
            raise ApiError(401, "invalid_claim_token", "Claim token was not recognized.")
        unit = self.store.unit_by_claim_hash(hash_secret(claim_token))
        if unit is None or not unit["slug"]:
            raise ApiError(401, "invalid_claim_token", "Claim token was not recognized.")
        return unit

    def _slug_for_unit(self, unit_id: str) -> str | None:
        row = self.store.unit_by_id(unit_id)
        if row is None:
            return None
        return row["slug"]

    def _setup_complete(self, unit_id: str) -> bool:
        row = self.store.unit_by_id(unit_id)
        return bool(row and row["setup_completed_at"])

    def _handoff_from_row(self, row, *, replayed: bool) -> dict[str, Any]:
        dns = json.loads(row["dns_json"])
        cert = json.loads(row["cert_json"])
        return {
            "status": "issued",
            "replayed": replayed,
            "unit_id": row["unit_id"],
            "slug": row["slug"],
            "domain": family_domain(row["slug"], self.settings.base_domain),
            "provider": row["provider"],
            "published": bool(row["published"]),
            "edge_certificate_ready": bool(cert.get("ready")),
            "tunnel": {
                "tunnel_id": row["cf_tunnel_id"],
                "account_tag": row["account_tag"],
                "token": row["token"],
                "credentials_file": json.loads(row["credentials_json"]),
            },
            "dns": dns,
            "certificate": cert,
            "excluded_from_proxy": json.loads(row["excluded_json"]),
            "origin_service": TUNNEL_ORIGIN_SERVICE,
        }
