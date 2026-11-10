"""Environment the operator sets on the control-plane host. See docs/CONTROL_PLANE.md."""

from __future__ import annotations

import os
from dataclasses import dataclass

from tinyweb_controlplane.hosts import repo_root

ALLOWED_CERT_METHODS = ("advanced", "total_tls")
ALLOWED_CERT_AUTHORITIES = ("lets_encrypt", "google", "ssl_com")
ALLOWED_PROVIDERS = ("cloudflare", "fake")


def _flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass
class Settings:
    base_domain: str = "tinyweb.win"
    public_origin: str = "https://tinyweb.win"
    db_path: str = ""
    operator_token: str = ""
    ddns_token: str = ""
    provider_name: str = "cloudflare"
    cf_api_token: str = ""
    cf_account_id: str = ""
    cf_zone_id: str = ""
    cf_api_base: str = "https://api.cloudflare.com/client/v4"
    edge_cert_method: str = "advanced"
    cert_authority: str = "lets_encrypt"
    host: str = "127.0.0.1"
    port: int = 8787
    location_app: str = "owntracks"
    events_app: str = "mobilizon"
    push_enabled: bool = True

    def __post_init__(self) -> None:
        self.provider_name = self.provider_name.strip().lower()
        self.edge_cert_method = self.edge_cert_method.strip().lower()
        self.cert_authority = self.cert_authority.strip().lower()
        self.base_domain = self.base_domain.strip().lower().rstrip(".")
        self.public_origin = self.public_origin.rstrip("/")
        if not self.db_path:
            self.db_path = str(repo_root() / "controlplane" / "var" / "control-plane.sqlite")
        if self.provider_name not in ALLOWED_PROVIDERS:
            raise ValueError(
                "TWS_CONTROL_PLANE_PROVIDER must be cloudflare or fake "
                f"(got {self.provider_name!r})"
            )
        if self.edge_cert_method not in ALLOWED_CERT_METHODS:
            raise ValueError(
                "TWS_EDGE_CERT_METHOD must be advanced or total_tls "
                f"(got {self.edge_cert_method!r})"
            )
        if self.cert_authority not in ALLOWED_CERT_AUTHORITIES:
            raise ValueError(
                "TWS_CERT_AUTHORITY must be lets_encrypt, google, or ssl_com "
                f"(got {self.cert_authority!r})"
            )

    @classmethod
    def from_env(cls) -> Settings:
        port_raw = os.environ.get("TWS_CONTROL_PLANE_PORT", "8787")
        try:
            port = int(port_raw)
        except ValueError as exc:
            raise ValueError("TWS_CONTROL_PLANE_PORT must be an integer") from exc
        return cls(
            base_domain=os.environ.get("TWS_BASE_DOMAIN", "tinyweb.win"),
            public_origin=os.environ.get("TWS_CONTROL_PLANE_PUBLIC_ORIGIN", "https://tinyweb.win"),
            db_path=os.environ.get("TWS_CONTROL_PLANE_DB", ""),
            operator_token=os.environ.get("TWS_CONTROL_PLANE_OPERATOR_TOKEN", ""),
            ddns_token=os.environ.get("TWS_DDNS_TOKEN", ""),
            provider_name=os.environ.get("TWS_CONTROL_PLANE_PROVIDER", "cloudflare"),
            cf_api_token=os.environ.get("CF_API_TOKEN", ""),
            cf_account_id=os.environ.get("CF_ACCOUNT_ID", ""),
            cf_zone_id=os.environ.get("CF_ZONE_ID", ""),
            cf_api_base=os.environ.get("CF_API_BASE", "https://api.cloudflare.com/client/v4"),
            edge_cert_method=os.environ.get("TWS_EDGE_CERT_METHOD", "advanced"),
            cert_authority=os.environ.get("TWS_CERT_AUTHORITY", "lets_encrypt"),
            host=os.environ.get("TWS_CONTROL_PLANE_HOST", "127.0.0.1"),
            port=port,
            location_app=os.environ.get("LOCATION_APP", "owntracks"),
            events_app=os.environ.get("EVENTS_APP", "mobilizon"),
            push_enabled=_flag("TWS_PUSH_ENABLE", True),
        )
