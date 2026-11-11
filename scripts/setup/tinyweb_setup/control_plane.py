"""Calls the tinyweb.win control plane.

Secrets travel in the JSON body or the Authorization header. This module never
puts them in a query string and never writes them to a log line.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

_CODE_RE = re.compile(r"^[A-Za-z0-9_-]{22,128}$")
_LOOPBACK = {"127.0.0.1", "localhost"}


class ControlPlaneError(Exception):
    def __init__(self, message: str, *, status: int = 0, code: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.status = status
        self.code = code


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(  # noqa: ANN201
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ):
        raise ControlPlaneError(
            "The control plane redirected the request. Refusing to follow it.",
            status=code,
            code="redirect",
        )


def code_is_strong(code: str) -> bool:
    """URL-safe token of at least 128 bits (token_urlsafe(16) is 22 characters)."""
    return bool(_CODE_RE.fullmatch(code))


def normalize_base_url(url: str) -> str:
    text = url.strip()
    if any(ch.isspace() for ch in text):
        raise ControlPlaneError(
            "The control plane URL must not contain a secret, a query, or a user name.",
            code="bad_url",
        )
    parsed = urllib.parse.urlparse(text)
    host = (parsed.hostname or "").lower()
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ControlPlaneError(
            "The control plane URL must not contain a secret, a query, or a user name.",
            code="bad_url",
        )
    if parsed.scheme == "https" and host:
        return text.rstrip("/")
    if parsed.scheme == "http" and host in _LOOPBACK:
        return text.rstrip("/")
    raise ControlPlaneError(
        "The control plane URL must be https, or http on localhost for tests.",
        code="bad_url",
    )


@dataclass(frozen=True)
class PublishDecision:
    name_ready: bool
    certificate_ready: bool
    tunnel_ready: bool
    complete: bool
    reason: str


def evaluate_handoff(handoff: dict[str, Any] | None, apply_exit: int | None) -> PublishDecision:
    """Gates from a tunnel handoff. Missing or unpublished stays not ready.

    A certificate or a tunnel is ready only when the control plane says the
    DNS records were published. A Jellyfin hostname on that list is not a failure.
    """
    if not isinstance(handoff, dict):
        return PublishDecision(False, False, False, False, "missing")
    published = handoff.get("published") is True
    cert_ready = handoff.get("edge_certificate_ready") is True
    certificate = handoff.get("certificate")
    if isinstance(certificate, dict) and certificate.get("ready") is not True:
        cert_ready = False
    name_ready = published
    certificate_ready = published and cert_ready
    tunnel_ready = published and apply_exit == 0
    if not published:
        reason = "unpublished"
    elif not cert_ready:
        reason = "certificate_pending"
    elif apply_exit != 0:
        reason = "tunnel_failed"
    else:
        reason = "ready"
    return PublishDecision(
        name_ready,
        certificate_ready,
        tunnel_ready,
        name_ready and certificate_ready and tunnel_ready,
        reason,
    )


class ControlPlaneClient:
    def __init__(self, base_url: str, *, timeout: float = 20.0) -> None:
        self.base_url = normalize_base_url(base_url)
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_NoRedirect)

    def check_slug(self, slug: str) -> dict[str, Any]:
        return self._request("GET", f"/v1/slugs/{urllib.parse.quote(slug, safe='')}")

    def claim(self, setup_code: str, slug: str) -> dict[str, Any]:
        return self._request("POST", "/v1/setup/claim", body={"setup_code": setup_code, "slug": slug})

    def issue_tunnel(self, claim_token: str, *, jellyfin: bool = False) -> dict[str, Any]:
        return self._request(
            "POST",
            "/v1/tunnels",
            body={"jellyfin": jellyfin},
            bearer=claim_token,
        )

    def update_hosts(self, claim_token: str, *, jellyfin: bool) -> dict[str, Any]:
        """Add or remove the Jellyfin host on a tunnel that already exists.

        Uses the claim token from setup. The setup code is not sent.
        """
        return self._request(
            "POST",
            "/v1/tunnels/hosts",
            body={"jellyfin": jellyfin},
            bearer=claim_token,
        )

    def complete(self, claim_token: str) -> dict[str, Any]:
        return self._request("POST", "/v1/setup/complete", body={}, bearer=claim_token)

    def mint_unit(self, operator_token: str) -> dict[str, Any]:
        return self._request("POST", "/v1/operator/units", bearer=operator_token)

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        bearer: str | None = None,
    ) -> dict[str, Any]:
        if "?" in path or path.startswith("http") or not path.startswith("/"):
            raise ControlPlaneError(
                "Refusing to put a control-plane request in a query string.",
                code="secret_in_query",
            )
        data = None
        headers = {"Accept": "application/json", "User-Agent": "tinyweb-setup"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = response.read()
                status = int(response.status)
        except ControlPlaneError:
            raise
        except urllib.error.HTTPError as exc:
            detail = exc.read()
            raise _http_error(exc.code, detail) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ControlPlaneError(
                "Could not reach the control plane.",
                code="unreachable",
            ) from None
        return _decode(raw, status)


def _decode(raw: bytes, status: int) -> dict[str, Any]:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ControlPlaneError(
            "The control plane returned a response TinyWeb could not read.",
            status=status,
            code="bad_response",
        ) from exc
    if not isinstance(payload, dict):
        raise ControlPlaneError(
            "The control plane returned a response TinyWeb could not read.",
            status=status,
            code="bad_response",
        )
    if status >= 400:
        raise ControlPlaneError(
            "The control plane rejected the request.",
            status=status,
            code=str(payload.get("error") or "http_error"),
        )
    return payload


def _http_error(status: int, raw: bytes) -> ControlPlaneError:
    code = "http_error"
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        payload = None
    if isinstance(payload, dict) and payload.get("error"):
        code = str(payload["error"])
    return ControlPlaneError(
        "The control plane rejected the request.",
        status=status,
        code=code,
    )
