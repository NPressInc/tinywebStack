"""HTTP contract for the box and, later, the phone.

Family traffic is not proxied here. Secrets are accepted in the JSON body or
the Authorization header, never in the query string.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.errors import ApiError
from tinyweb_controlplane.providers import build_provider
from tinyweb_controlplane.redact import install_log_redaction
from tinyweb_controlplane.security import hash_secret, secrets_equal
from tinyweb_controlplane.service import Service, TunnelOptions
from tinyweb_controlplane.slugs import validate_slug
from tinyweb_controlplane.store import Store

_QUERY_SECRETS = {"code", "setup_code", "claim_token", "token"}


class ClaimIn(BaseModel):
    setup_code: str
    slug: str


class IssueIn(BaseModel):
    location_app: str = "owntracks"
    events_app: str = "mobilizon"
    push: bool = True
    jellyfin: bool = False


class RevokeIn(BaseModel):
    slug: str


class DdnsIn(BaseModel):
    token: str
    domain: str
    wildcard: str = ""
    ipv4: str = ""
    ipv6: str = ""


def create_app(
    settings: Settings | None = None,
    *,
    provider: Any = None,
    store: Store | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    store = store or Store(settings.db_path)
    provider = provider if provider is not None else build_provider(settings)
    service = Service(settings, store, provider)
    install_log_redaction()

    app = FastAPI(
        title="TinyWeb control plane",
        version="0.1.0",
        description=(
            "Reserve a family name, publish DNS, order the edge certificate, "
            "and issue per-box Cloudflare Tunnel credentials. "
            "Family traffic does not pass through this service."
        ),
    )
    app.state.settings = settings
    app.state.store = store
    app.state.provider = provider
    app.state.service = service

    @app.middleware("http")
    async def reject_secret_query(request: Request, call_next):
        keys = {key.lower() for key in request.query_params.keys()}
        if keys & _QUERY_SECRETS:
            return JSONResponse(
                status_code=400,
                content={
                    "error": "secret_in_query",
                    "detail": (
                        "Send secrets in the JSON body or the Authorization header. "
                        "The factory QR keeps the setup code in the URL fragment so it is not logged."
                    ),
                },
            )
        return await call_next(request)

    @app.exception_handler(ApiError)
    async def api_error(_request: Request, exc: ApiError) -> JSONResponse:
        body: dict[str, Any] = {"error": exc.code, "detail": exc.detail}
        body.update(exc.extra)
        return JSONResponse(status_code=exc.status_code, content=body)

    def bearer(request: Request) -> str | None:
        header = request.headers.get("authorization", "")
        scheme, _, value = header.partition(" ")
        if scheme.lower() != "bearer" or not value.strip():
            return None
        return value.strip()

    def require_operator(request: Request) -> None:
        if not settings.operator_token:
            raise ApiError(
                503,
                "operator_not_configured",
                "Set TWS_CONTROL_PLANE_OPERATOR_TOKEN on the control plane.",
            )
        token = bearer(request)
        if token is None or not secrets_equal(token, settings.operator_token):
            raise ApiError(401, "unauthorized", "Operator token rejected.")

    def box_unit(request: Request):
        token = bearer(request)
        if token is None:
            raise ApiError(401, "unauthorized", "Bearer claim token required.")
        if settings.operator_token and secrets_equal(token, settings.operator_token):
            raise ApiError(
                403,
                "use_claim_token",
                "Use the box claim token for this call. The operator token cannot take over a box.",
            )
        unit = store.unit_by_claim_hash(hash_secret(token))
        if unit is None or not unit["slug"]:
            raise ApiError(401, "invalid_claim_token", "Claim token was not recognized.")
        return token, unit

    @app.get("/v1/health")
    def health() -> dict[str, Any]:
        return {
            "ok": True,
            "service": "tinyweb-control-plane",
            "provider": provider.name,
        }

    @app.get("/v1/slugs/{slug}")
    def check_slug(slug: str) -> dict[str, Any]:
        return service.check_slug(slug)

    @app.post("/v1/operator/units", status_code=201)
    def mint_unit(request: Request) -> dict[str, Any]:
        require_operator(request)
        return service.mint_unit()

    @app.post("/v1/setup/claim")
    def claim(body: ClaimIn) -> dict[str, Any]:
        return service.claim(body.setup_code, body.slug)

    @app.post("/v1/setup/complete")
    def complete(request: Request) -> dict[str, Any]:
        token, _unit = box_unit(request)
        return service.complete(token)

    @app.post("/v1/tunnels")
    def issue_tunnel(body: IssueIn, request: Request) -> dict[str, Any]:
        token, _unit = box_unit(request)
        options = TunnelOptions(
            location_app=body.location_app,
            events_app=body.events_app,
            push=body.push,
            jellyfin=body.jellyfin,
        )
        return service.issue_tunnel(token, options)

    @app.post("/v1/tunnels/hosts")
    async def update_hosts(request: Request) -> dict[str, Any]:
        token, _unit = box_unit(request)
        try:
            payload = await request.json()
        except Exception as exc:
            raise ApiError(
                400,
                "invalid_body",
                "Send a JSON object with jellyfin set to true or false.",
            ) from exc
        if not isinstance(payload, dict):
            raise ApiError(
                400,
                "invalid_body",
                "Send a JSON object with jellyfin set to true or false.",
            )
        unknown = set(payload) - {"jellyfin"}
        if unknown:
            raise ApiError(
                400,
                "invalid_host",
                "Only the Jellyfin host can be changed here. Immich is out of scope for v1.",
            )
        if not isinstance(payload.get("jellyfin"), bool):
            raise ApiError(400, "invalid_body", "jellyfin must be true or false.")
        return service.update_hosts(token, jellyfin=payload["jellyfin"])

    @app.post("/v1/tunnels/revoke")
    def revoke(body: RevokeIn, request: Request) -> dict[str, Any]:
        slug = validate_slug(body.slug)
        token = bearer(request)
        if token is None:
            raise ApiError(401, "unauthorized", "Bearer token required.")
        if settings.operator_token and secrets_equal(token, settings.operator_token):
            reserved = store.slug_row(slug)
            if reserved is None:
                raise ApiError(404, "unknown_family", f"{slug} is not reserved.")
            return service.revoke(unit_id=reserved["unit_id"])
        _raw, unit = box_unit(request)
        if unit["slug"] != slug:
            raise ApiError(403, "forbidden", "This claim token cannot revoke another family.")
        return service.revoke(unit_id=unit["unit_id"])

    @app.get("/v1/families/{slug}")
    def family_status(slug: str, request: Request) -> dict[str, Any]:
        token = bearer(request)
        if token is None:
            raise ApiError(401, "unauthorized", "Bearer token required.")
        checked = validate_slug(slug)
        if settings.operator_token and secrets_equal(token, settings.operator_token):
            return service.family_status(checked)
        _raw, unit = box_unit(request)
        if unit["slug"] != checked:
            raise ApiError(403, "forbidden", "This claim token cannot read another family.")
        return service.family_status(checked)

    @app.post("/v1/ddns")
    def ddns(body: DdnsIn) -> dict[str, Any]:
        # ipv4, ipv6, and wildcard match scripts/vm/tinyweb-subdomain-ddns.sh.
        # They are ignored: tunnel DNS stays a proxied CNAME.
        del body.wildcard, body.ipv4, body.ipv6
        return service.ddns(token=body.token, domain=body.domain)

    return app
