"""FastAPI family dashboard (server-rendered, YunoHost SSO)."""

from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import Any, Dict, List

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeSerializer

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    list_group_members,
    require_parent,
    username_from_headers,
)
from tinywebstack_dashboard.policy_store import load_policy, save_policy, set_parent_mxids, sync_kids_from_usernames

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
        return data

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
