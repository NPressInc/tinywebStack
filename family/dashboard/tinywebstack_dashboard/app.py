"""FastAPI family dashboard (server-rendered, YunoHost SSO)."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeSerializer

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    list_group_members,
    require_parent,
    username_from_headers,
)
from tinywebstack_dashboard.invite_store import add_pending, load_pending
from tinywebstack_dashboard.peer_verify import verify_peer_domain
from tinywebstack_dashboard.policy_store import load_policy, save_policy, set_parent_mxids, sync_kids_from_usernames
from tinywebstack_family.invite import create_invite_token, verify_invite_token

TEMPLATES = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


def config_from_env() -> DashboardConfig:
    return DashboardConfig(
        parents_group=os.environ.get("TWS_PARENTS_GROUP", "parents"),
        kids_group=os.environ.get("TWS_KIDS_GROUP", "kids"),
        policy_path=os.environ.get("TWS_POLICY_PATH", "/etc/tinywebstack/family-policy.json"),
        server_name=os.environ.get("TWS_SERVER_NAME", ""),
        location_base_url=os.environ.get("TWS_LOCATION_URL", ""),
        csrf_secret=os.environ.get("TWS_CSRF_SECRET", secrets.token_hex(32)),
        yunohost_cli=os.environ.get("TWS_YUNOHOST_CLI", "yunohost"),
    )


def create_app(cfg: DashboardConfig | None = None) -> FastAPI:
    cfg = cfg or config_from_env()
    app = FastAPI(title="tinywebStack Family Dashboard")
    serializer = URLSafeSerializer(cfg.csrf_secret, salt="tws-csrf")
    policy_path = Path(cfg.policy_path)
    pending_path = Path(os.environ.get("TWS_PENDING_INVITES_PATH", "/etc/tinywebstack/pending-invites.json"))
    invite_secret = os.environ.get("TWS_INVITE_SECRET", "")
    matrix_server = os.environ.get("TWS_MATRIX_SERVER", cfg.server_name)
    federation_sync_cmd = os.environ.get("TWS_FEDERATION_SYNC_CMD", "")

    def current_user(request: Request) -> str:
        user = username_from_headers(dict(request.headers))
        require_parent(user, cfg)
        return user  # type: ignore[return-value]

    def csrf_token(request: Request) -> str:
        return serializer.dumps({"n": secrets.token_hex(8)})

    def verify_csrf(request: Request, token: str) -> None:
        try:
            serializer.loads(token)
        except BadSignature as exc:
            raise HTTPException(status_code=400, detail="Invalid CSRF token") from exc

    def refreshed_policy() -> Dict[str, Any]:
        kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
        parents = list_group_members(cfg.parents_group, cfg.yunohost_cli)
        server = cfg.server_name
        if not server:
            raise HTTPException(status_code=500, detail="TWS_SERVER_NAME not configured")
        data = load_policy(policy_path)
        data = sync_kids_from_usernames(data, kids, server)
        set_parent_mxids(data, parents, server)
        data.setdefault("reject_encryption", True)
        data.setdefault("trusted_domains", data.get("trusted_domains") or [])
        return data

    def ensure_invite_secret() -> str:
        nonlocal invite_secret
        if invite_secret:
            return invite_secret
        raise HTTPException(status_code=500, detail="TWS_INVITE_SECRET not configured")

    def add_trusted_domain(domain: str) -> None:
        policy = refreshed_policy()
        trusted = set(policy.get("trusted_domains") or [])
        if domain not in trusted:
            trusted.add(domain)
            policy["trusted_domains"] = sorted(trusted)
            save_policy(policy_path, policy)
        if federation_sync_cmd:
            subprocess.run(
                federation_sync_cmd.split(),
                check=False,
                timeout=120,
            )

    def post_json(url: str, body: Dict[str, Any], timeout: int = 20) -> Dict[str, Any]:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    @app.get("/.well-known/tinywebstack-family.json")
    async def well_known_family():
        return JSONResponse(
            {
                "server_name": cfg.server_name,
                "matrix_server": matrix_server or cfg.server_name,
                "invite_verify_url": "/family/api/invite/verify",
            }
        )

    @app.post("/api/invite/verify")
    async def api_invite_verify(request: Request):
        """Public: peer verifies one-time invite and registers redeemer domain."""
        try:
            body = await request.json()
        except Exception as exc:
            raise HTTPException(status_code=400, detail="JSON body required") from exc
        token = str(body.get("token", "")).strip()
        redeemer = str(body.get("redeemer_domain", "")).strip()
        if not token or not redeemer:
            raise HTTPException(status_code=400, detail="token and redeemer_domain required")
        try:
            payload = verify_invite_token(token, ensure_invite_secret())
        except ValueError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        pending = load_pending(pending_path).get("invites", {}).get(payload["nonce"])
        if not pending or pending.get("used"):
            raise HTTPException(status_code=403, detail="Invite not valid or already used")
        key_doc = verify_peer_domain(cfg.server_name, matrix_server or None)
        add_pending(
            pending_path,
            payload["nonce"],
            {**pending, "used": True, "redeemer_domain": redeemer},
        )
        add_trusted_domain(redeemer)
        return JSONResponse(
            {
                "issuer_domain": cfg.server_name,
                "matrix_server_key": key_doc,
                "redeemer_domain": redeemer,
            }
        )

    @app.get("/invite", response_class=HTMLResponse)
    async def invite_page(request: Request, user: str = Depends(current_user)):
        return TEMPLATES.TemplateResponse(
            request,
            "invite.html",
            {"user": user, "csrf": csrf_token(request), "token": "", "invite_url": ""},
        )

    @app.post("/invite/create")
    async def invite_create(
        request: Request,
        user: str = Depends(current_user),
        csrf: str = Form(...),
    ):
        verify_csrf(request, csrf)
        secret = ensure_invite_secret()
        token, nonce = create_invite_token(cfg.server_name, secret)
        add_pending(
            pending_path,
            nonce,
            {"created_by": user, "issuer": cfg.server_name},
        )
        base = os.environ.get("TWS_PUBLIC_BASE_URL", f"https://{cfg.server_name}/family")
        invite_url = f"{base.rstrip('/')}/invite/redeem?token={token}"
        return TEMPLATES.TemplateResponse(
            request,
            "invite.html",
            {"user": user, "csrf": csrf_token(request), "token": token, "invite_url": invite_url},
        )

    @app.get("/invite/redeem", response_class=HTMLResponse)
    async def invite_redeem_form(
        request: Request,
        user: str = Depends(current_user),
        token: str = "",
    ):
        return TEMPLATES.TemplateResponse(
            request,
            "invite_redeem.html",
            {"user": user, "csrf": csrf_token(request), "token": token, "message": ""},
        )

    @app.post("/invite/redeem")
    async def invite_redeem_submit(
        request: Request,
        user: str = Depends(current_user),
        csrf: str = Form(...),
        token: str = Form(...),
    ):
        verify_csrf(request, csrf)
        token = token.strip()
        try:
            from tinywebstack_family.invite import decode_invite_token

            decoded = decode_invite_token(token)
            issuer = str(decoded["p"]["domain"])
        except Exception as exc:
            raise HTTPException(status_code=400, detail=f"Invalid token: {exc}") from exc
        if issuer == cfg.server_name:
            raise HTTPException(
                status_code=400,
                detail="This invite was issued on this server; give it to the other household.",
            )
        peer_base = os.environ.get("TWS_PEER_INVITE_VERIFY_BASE", f"https://{issuer}/family")
        verify_url = f"{peer_base.rstrip('/')}/api/invite/verify"
        message = ""
        try:
            post_json(
                verify_url,
                {"token": token, "redeemer_domain": cfg.server_name},
            )
            verify_peer_domain(issuer, None)
            add_trusted_domain(issuer)
            message = f"Linked with {issuer}. Federation allowlist sync requested."
        except (urllib.error.URLError, OSError) as exc:
            message = f"Could not reach peer at {verify_url}: {exc}"
        return TEMPLATES.TemplateResponse(
            request,
            "invite_redeem.html",
            {"user": user, "csrf": csrf_token(request), "token": token, "message": message},
        )

    @app.get("/", response_class=HTMLResponse)
    async def index(request: Request, user: str = Depends(current_user)):
        policy = refreshed_policy()
        kids = policy.get("kids") or {}
        return TEMPLATES.TemplateResponse(
            request,
            "index.html",
            {
                "user": user,
                "kids": sorted(kids.keys()),
                "location_url": cfg.location_base_url,
                "csrf": csrf_token(request),
            },
        )

    @app.get("/kid/{kid_mxid:path}", response_class=HTMLResponse)
    async def edit_kid(request: Request, kid_mxid: str, user: str = Depends(current_user)):
        policy = refreshed_policy()
        entry = (policy.get("kids") or {}).get(kid_mxid)
        if not entry:
            raise HTTPException(status_code=404, detail="Unknown kid")
        qh = entry.get("quiet_hours") or {}
        return TEMPLATES.TemplateResponse(
            request,
            "kid_edit.html",
            {
                "user": user,
                "kid_mxid": kid_mxid,
                "allowlist_mxids": "\n".join(entry.get("allowlist_mxids") or []),
                "allowlist_domains": "\n".join(entry.get("allowlist_domains") or []),
                "qh_start": qh.get("start", ""),
                "qh_end": qh.get("end", ""),
                "qh_timezone": qh.get("timezone", "UTC"),
                "csrf": csrf_token(request),
            },
        )

    @app.post("/kid/{kid_mxid:path}")
    async def save_kid(
        request: Request,
        kid_mxid: str,
        user: str = Depends(current_user),
        csrf: str = Form(...),
        allowlist_mxids: str = Form(""),
        allowlist_domains: str = Form(""),
        qh_start: str = Form(""),
        qh_end: str = Form(""),
        qh_timezone: str = Form("UTC"),
    ):
        verify_csrf(request, csrf)
        policy = refreshed_policy()
        if kid_mxid not in (policy.get("kids") or {}):
            raise HTTPException(status_code=404, detail="Unknown kid")
        mxids = [ln.strip() for ln in allowlist_mxids.splitlines() if ln.strip()]
        domains = [ln.strip() for ln in allowlist_domains.splitlines() if ln.strip()]
        entry: Dict[str, Any] = {
            "allowlist_mxids": mxids,
            "allowlist_domains": domains,
        }
        if qh_start and qh_end:
            entry["quiet_hours"] = {
                "start": qh_start,
                "end": qh_end,
                "timezone": qh_timezone or "UTC",
                "days": list(range(7)),
            }
        policy["kids"][kid_mxid] = entry
        save_policy(policy_path, policy)
        return RedirectResponse(url="/", status_code=303)

    return app


app = create_app()
