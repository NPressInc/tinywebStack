"""Cloudflare calls, and a fake provider for tests.

The fake provider never reports that a public hostname was published.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx

from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.errors import ProviderError, ProviderNotConfigured
from tinyweb_controlplane.hosts import UNIVERSAL_SSL_NOTE


@dataclass
class IngressRule:
    hostname: str
    service: str
    http_host_header: str


@dataclass
class TunnelSpec:
    name: str
    rules: list[IngressRule]


@dataclass
class IssuedTunnel:
    tunnel_id: str
    account_tag: str
    token: str
    credentials_file: dict[str, str]
    name: str


@dataclass
class DnsRecord:
    name: str
    type: str
    content: str
    proxied: bool

    def as_dict(self, *, applied: bool) -> dict[str, Any]:
        return {
            "name": self.name,
            "type": self.type,
            "content": self.content,
            "proxied": self.proxied,
            "applied": applied,
        }


@dataclass
class CertRequest:
    method: str
    hosts: list[str]


@dataclass
class EdgeCertificate:
    method: str
    hosts: list[str]
    status: str
    pack_id: str | None
    ready: bool
    note: str = UNIVERSAL_SSL_NOTE

    def as_dict(self) -> dict[str, Any]:
        return {
            "method": self.method,
            "hosts": list(self.hosts),
            "status": self.status,
            "pack_id": self.pack_id,
            "ready": self.ready,
            "note": self.note,
        }


class ControlProvider(Protocol):
    publishes: bool
    name: str

    def create_tunnel(self, spec: TunnelSpec) -> IssuedTunnel: ...

    def delete_tunnel(self, tunnel_id: str) -> None: ...

    def upsert_cname(self, record: DnsRecord) -> None: ...

    def delete_cname(self, name: str) -> None: ...

    def ensure_edge_certificate(self, request: CertRequest) -> EdgeCertificate: ...


@dataclass
class FakeProvider:
    """In-memory stand-in. publishes is always false."""

    publishes: bool = False
    name: str = "fake"
    tunnels: dict[str, dict[str, Any]] = field(default_factory=dict)
    records: dict[str, DnsRecord] = field(default_factory=dict)
    certs: list[CertRequest] = field(default_factory=list)
    deleted_tunnels: list[str] = field(default_factory=list)
    deleted_names: list[str] = field(default_factory=list)
    create_calls: int = 0
    fail_certificate: bool = False

    def create_tunnel(self, spec: TunnelSpec) -> IssuedTunnel:
        self.create_calls += 1
        for row in self.tunnels.values():
            if row["name"] == spec.name and not row["deleted"]:
                return row["issued"]
        number = len(self.tunnels) + 1
        tunnel_id = f"00000000-0000-4000-8000-{number:012d}"
        issued = IssuedTunnel(
            tunnel_id=tunnel_id,
            account_tag="fake-account",
            token=f"fake-tunnel-token-{number}",
            credentials_file={
                "AccountTag": "fake-account",
                "TunnelID": tunnel_id,
                "TunnelName": spec.name,
                "TunnelSecret": "fake-tunnel-secret",
            },
            name=spec.name,
        )
        self.tunnels[tunnel_id] = {
            "name": spec.name,
            "deleted": False,
            "issued": issued,
            "rules": list(spec.rules),
        }
        return issued

    def delete_tunnel(self, tunnel_id: str) -> None:
        self.deleted_tunnels.append(tunnel_id)
        row = self.tunnels.get(tunnel_id)
        if row is not None:
            row["deleted"] = True

    def upsert_cname(self, record: DnsRecord) -> None:
        if record.type != "CNAME":
            raise ProviderError("The control plane only writes tunnel CNAMEs")
        self.records[record.name] = record

    def delete_cname(self, name: str) -> None:
        self.deleted_names.append(name)
        self.records.pop(name, None)

    def ensure_edge_certificate(self, request: CertRequest) -> EdgeCertificate:
        if self.fail_certificate:
            raise ProviderError("fake certificate order failed")
        self.certs.append(request)
        return EdgeCertificate(
            method=request.method,
            hosts=list(request.hosts),
            status="ordered",
            pack_id=None,
            ready=False,
        )


class UnconfiguredProvider:
    """Cloudflare was selected, but the operator has not provided secrets yet."""

    publishes = False
    name = "cloudflare"

    def __init__(self, missing: list[str]) -> None:
        self.missing = list(missing)

    def _fail(self) -> None:
        raise ProviderNotConfigured(self.missing)

    def create_tunnel(self, spec: TunnelSpec) -> IssuedTunnel:
        self._fail()
        raise AssertionError

    def delete_tunnel(self, tunnel_id: str) -> None:
        self._fail()

    def upsert_cname(self, record: DnsRecord) -> None:
        self._fail()

    def delete_cname(self, name: str) -> None:
        self._fail()

    def ensure_edge_certificate(self, request: CertRequest) -> EdgeCertificate:
        self._fail()
        raise AssertionError


class CloudflareProvider:
    """Official remote-tunnel API. One tunnel per box, config stored at Cloudflare."""

    publishes = True
    name = "cloudflare"

    def __init__(
        self,
        *,
        account_id: str,
        zone_id: str,
        api_token: str,
        base_domain: str,
        cert_method: str,
        cert_authority: str,
        api_base: str = "https://api.cloudflare.com/client/v4",
        client: httpx.Client | None = None,
    ) -> None:
        self.account_id = account_id
        self.zone_id = zone_id
        self._api_token = api_token
        self.base_domain = base_domain
        self.cert_method = cert_method
        self.cert_authority = cert_authority
        # Relative request paths are joined onto this base. A leading slash would
        # drop /client/v4, so callers pass "accounts/..." and "zones/...".
        self._client = client or httpx.Client(
            base_url=api_base.rstrip("/") + "/",
            timeout=30.0,
        )

    def _scrub(self, text: str) -> str:
        if self._api_token and self._api_token in text:
            return text.replace(self._api_token, "[redacted]")
        return text

    def _request(
        self,
        method: str,
        path: str,
        json_body: dict[str, Any] | None = None,
        params: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        try:
            response = self._client.request(
                method,
                path,
                json=json_body,
                params=params,
                headers={
                    "Authorization": f"Bearer {self._api_token}",
                    "Content-Type": "application/json",
                },
            )
        except httpx.HTTPError as exc:
            raise ProviderError(self._scrub(f"Cloudflare request failed: {exc}")) from None
        try:
            data = response.json()
        except ValueError:
            raise ProviderError(
                f"Cloudflare returned a non-JSON response ({response.status_code})"
            ) from None
        if not isinstance(data, dict):
            raise ProviderError(f"Cloudflare returned an unexpected payload ({response.status_code})")
        if response.status_code >= 400 or not data.get("success", False):
            parts: list[str] = []
            for err in data.get("errors") or []:
                if isinstance(err, dict):
                    parts.append(f"{err.get('code')}: {err.get('message')}")
                else:
                    parts.append(self._scrub(str(err)))
            detail = "; ".join(parts) or f"HTTP {response.status_code}"
            raise ProviderError(
                f"Cloudflare API error: {self._scrub(detail)}",
                status_code=response.status_code,
            )
        return data

    def _find_tunnel(self, name: str) -> dict[str, Any] | None:
        data = self._request(
            "GET",
            f"accounts/{self.account_id}/cfd_tunnel",
            params={"name": name, "is_deleted": "false"},
        )
        result = data.get("result") or []
        if isinstance(result, dict):
            result = [result]
        for row in result:
            if isinstance(row, dict) and row.get("name") == name and not row.get("deleted_at"):
                return row
        return None

    def _fetch_token(self, tunnel_id: str) -> str:
        data = self._request("GET", f"accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/token")
        result = data.get("result")
        if isinstance(result, str):
            return result
        if isinstance(result, dict):
            return str(result.get("token") or "")
        return ""

    def _put_ingress(self, tunnel_id: str, spec: TunnelSpec) -> None:
        rules: list[dict[str, Any]] = []
        for rule in spec.rules:
            rules.append(
                {
                    "hostname": rule.hostname,
                    "service": rule.service,
                    "originRequest": {
                        "noTLSVerify": True,
                        "httpHostHeader": rule.http_host_header,
                    },
                }
            )
        rules.append({"service": "http_status:404"})
        self._request(
            "PUT",
            f"accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/configurations",
            {"config": {"ingress": rules}},
        )

    def create_tunnel(self, spec: TunnelSpec) -> IssuedTunnel:
        existing = self._find_tunnel(spec.name)
        created_now = existing is None
        if existing is None:
            created = self._request(
                "POST",
                f"accounts/{self.account_id}/cfd_tunnel",
                {"name": spec.name, "config_src": "cloudflare"},
            )
            result = created.get("result") or {}
        else:
            result = existing
        if not isinstance(result, dict) or not result.get("id"):
            raise ProviderError("Cloudflare did not return a tunnel id")
        tunnel_id = str(result["id"])
        account_tag = str(result.get("account_tag") or self.account_id)
        token = str(result.get("token") or "") or self._fetch_token(tunnel_id)
        if not token:
            if created_now:
                self._safe_delete(tunnel_id)
            raise ProviderError("Cloudflare did not return a tunnel token")
        credentials = result.get("credentials_file")
        if not isinstance(credentials, dict):
            credentials = {
                "AccountTag": account_tag,
                "TunnelID": tunnel_id,
                "TunnelName": spec.name,
            }
        credentials = {str(key): str(value) for key, value in credentials.items()}
        try:
            self._put_ingress(tunnel_id, spec)
        except ProviderError:
            if created_now:
                self._safe_delete(tunnel_id)
            raise
        return IssuedTunnel(
            tunnel_id=tunnel_id,
            account_tag=account_tag,
            token=token,
            credentials_file=credentials,
            name=spec.name,
        )

    def _safe_delete(self, tunnel_id: str) -> None:
        try:
            self.delete_tunnel(tunnel_id)
        except ProviderError:
            return

    def delete_tunnel(self, tunnel_id: str) -> None:
        try:
            self._request("DELETE", f"accounts/{self.account_id}/cfd_tunnel/{tunnel_id}")
        except ProviderError as exc:
            if exc.status_code == 404:
                return
            raise

    def _list_records(self, name: str) -> list[dict[str, Any]]:
        data = self._request(
            "GET",
            f"zones/{self.zone_id}/dns_records",
            params={"name": name, "per_page": "100"},
        )
        result = data.get("result") or []
        if not isinstance(result, list):
            return []
        return [row for row in result if isinstance(row, dict)]

    def upsert_cname(self, record: DnsRecord) -> None:
        if record.type != "CNAME" or not record.proxied:
            raise ProviderError("Tunnel DNS must be a proxied CNAME")
        existing = self._list_records(record.name)
        cname_id = None
        for row in existing:
            rtype = row.get("type")
            if rtype in {"A", "AAAA"} and row.get("id"):
                # The older DDNS helper writes A/AAAA at the home address.
                # A tunnel name cannot keep that record alongside the CNAME.
                self._request("DELETE", f"zones/{self.zone_id}/dns_records/{row['id']}")
            elif rtype == "CNAME" and row.get("id"):
                cname_id = str(row["id"])
        body = {
            "type": "CNAME",
            "name": record.name,
            "content": record.content,
            "proxied": True,
            "ttl": 1,
        }
        if cname_id:
            self._request("PUT", f"zones/{self.zone_id}/dns_records/{cname_id}", body)
        else:
            self._request("POST", f"zones/{self.zone_id}/dns_records", body)

    def delete_cname(self, name: str) -> None:
        for row in self._list_records(name):
            if row.get("type") == "CNAME" and row.get("id"):
                try:
                    self._request("DELETE", f"zones/{self.zone_id}/dns_records/{row['id']}")
                except ProviderError as exc:
                    if exc.status_code != 404:
                        raise

    def ensure_edge_certificate(self, request: CertRequest) -> EdgeCertificate:
        if request.method == "total_tls":
            data = self._request(
                "POST",
                f"zones/{self.zone_id}/acm/total_tls",
                {"enabled": True, "certificate_authority": self.cert_authority},
            )
            result = data.get("result") or {}
            enabled = bool(isinstance(result, dict) and result.get("enabled"))
            return EdgeCertificate(
                method="total_tls",
                hosts=list(request.hosts),
                status="enabled" if enabled else "unknown",
                pack_id=None,
                ready=False,
            )
        packs_data = self._request("GET", f"zones/{self.zone_id}/ssl/certificate_packs")
        packs = packs_data.get("result") or []
        want = set(request.hosts)
        if isinstance(packs, list):
            for pack in packs:
                if not isinstance(pack, dict) or pack.get("type") != "advanced":
                    continue
                if pack.get("status") in {"deleted", "expired"}:
                    continue
                have = set(pack.get("hosts") or [])
                if want.issubset(have):
                    status = str(pack.get("status") or "unknown")
                    return EdgeCertificate(
                        method="advanced_certificate_manager",
                        hosts=list(request.hosts),
                        status=status,
                        pack_id=str(pack["id"]) if pack.get("id") else None,
                        ready=status == "active",
                    )
        ordered = self._request(
            "POST",
            f"zones/{self.zone_id}/ssl/certificate_packs/order",
            {
                "certificate_authority": self.cert_authority,
                "hosts": list(request.hosts),
                "type": "advanced",
                "validation_method": "txt",
                "validity_days": 90,
                "cloudflare_branding": False,
            },
        )
        result = ordered.get("result") or {}
        if not isinstance(result, dict):
            result = {}
        status = str(result.get("status") or "pending_validation")
        pack_id = str(result["id"]) if result.get("id") else None
        return EdgeCertificate(
            method="advanced_certificate_manager",
            hosts=list(request.hosts),
            status=status,
            pack_id=pack_id,
            ready=status == "active",
        )


def build_provider(settings: Settings, client: httpx.Client | None = None) -> ControlProvider:
    if settings.provider_name == "fake":
        return FakeProvider()
    missing = []
    if not settings.cf_api_token:
        missing.append("CF_API_TOKEN")
    if not settings.cf_account_id:
        missing.append("CF_ACCOUNT_ID")
    if not settings.cf_zone_id:
        missing.append("CF_ZONE_ID")
    if missing:
        return UnconfiguredProvider(missing)
    return CloudflareProvider(
        account_id=settings.cf_account_id,
        zone_id=settings.cf_zone_id,
        api_token=settings.cf_api_token,
        base_domain=settings.base_domain,
        cert_method=settings.edge_cert_method,
        cert_authority=settings.cert_authority,
        api_base=settings.cf_api_base,
        client=client,
    )
