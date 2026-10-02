"""FastAPI family dashboard (server-rendered, YunoHost SSO)."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeSerializer

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    list_group_members,
    require_parent,
    username_from_headers,
)
from tinywebstack_dashboard.invite_store import add_pending, load_pending
from tinywebstack_dashboard.federation import (
    InvalidDomain,
    create_router as create_federation_router,
    normalize_domain,
    reconcile_state_with_policy,
    save_state as save_federation_state,
    state_path_from_env,
)
from tinywebstack_dashboard.peer_verify import _ssl_context, verify_peer_domain
from tinywebstack_dashboard.permissions import create_permissions_router
from tinywebstack_dashboard.members import list_members, matrix_status_label
from tinywebstack_dashboard.calendar_setup import caldav_account_url, davx5_login_hint
from tinywebstack_dashboard.owntracks_setup import (
    build_owntracks_config,
    load_stored_credentials,
    owntracks_otcp_link,
)
from tinywebstack_dashboard.policy_store import load_policy, save_policy, set_parent_mxids, sync_kids_from_usernames
from tinywebstack_dashboard.yunohost_actions import (
    create_member,
    delete_member,
    generate_password,
    issue_owntracks,
    reset_password,
    synapse_user_status,
    validate_username,
)
from tinywebstack_family.invite import create_invite_token, verify_invite_token
from tinywebstack_dashboard.urls import dash_url, dashboard_root_path

TEMPLATES = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


def config_from_env() -> DashboardConfig:
    return DashboardConfig(
        parents_group=os.environ.get("TWS_PARENTS_GROUP", "parents"),
        kids_group=os.environ.get("TWS_KIDS_GROUP", "kids"),
        policy_path=os.environ.get("TWS_POLICY_PATH", "/etc/tinywebstack/family-policy.json"),
        server_name=os.environ.get("TWS_SERVER_NAME", ""),
        location_base_url=os.environ.get("TWS_LOCATION_URL", ""),
        location_domain=os.environ.get("TWS_LOCATION_DOMAIN", ""),
        events_base_url=os.environ.get("TWS_EVENTS_URL", ""),
        caldav_root=os.environ.get("TWS_CALDAV_ROOT", ""),
        csrf_secret=os.environ.get("TWS_CSRF_SECRET", secrets.token_hex(32)),
        yunohost_cli=os.environ.get("TWS_YUNOHOST_CLI", "yunohost"),
        owntracks_store_path=os.environ.get(
            "TWS_OWNTRACKS_KIDS_FILE", "/etc/tinywebstack/owntracks-kids.json"
        ),
    )


def create_app(cfg: DashboardConfig | None = None) -> FastAPI:
    cfg = cfg or config_from_env()
    root_path = dashboard_root_path()
    TEMPLATES.env.globals["url"] = lambda path="/": dash_url(path, root_path)
    # Nginx strips /family/ before proxying; do not set FastAPI root_path (breaks static mounts).
    app = FastAPI(title="TinyWeb Family")
    static_dir = Path(__file__).parent / "static"
    if static_dir.is_dir():
        app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
    serializer = URLSafeSerializer(cfg.csrf_secret, salt="tws-csrf")
    policy_path = Path(cfg.policy_path)
    pending_path = Path(os.environ.get("TWS_PENDING_INVITES_PATH", "/etc/tinywebstack/pending-invites.json"))
    invite_secret = os.environ.get("TWS_INVITE_SECRET", "")
    matrix_server = os.environ.get("TWS_MATRIX_SERVER", cfg.server_name)
    federation_sync_cmd = os.environ.get("TWS_FEDERATION_SYNC_CMD", "")
    events_perms_cmd = os.environ.get("TWS_EVENTS_PERMS_CMD", "")
    federation_state_path = state_path_from_env()

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

    def schedule_federation_sync() -> None:
        if not federation_sync_cmd:
            return

        def _run() -> None:
            subprocess.run(federation_sync_cmd.split(), check=False, timeout=180)

        threading.Thread(target=_run, daemon=True).start()

    def add_trusted_domain(domain: str, *, sync: bool = True) -> None:
        merged = reconcile_state_with_policy(
            federation_state_path,
            policy_path,
            server_name=cfg.server_name,
        )
        try:
            domain = normalize_domain(domain)
        except InvalidDomain:
            return
        if domain not in merged:
            merged = sorted(set([*merged, domain]))
            save_federation_state(federation_state_path, merged)
            policy = refreshed_policy()
            policy["trusted_domains"] = merged
            save_policy(policy_path, policy)
        if sync:
            schedule_federation_sync()

    app.include_router(
        create_federation_router(cfg, state_path=federation_state_path, on_change=schedule_federation_sync)
    )

    def post_json(url: str, body: Dict[str, Any], timeout: int = 20) -> Dict[str, Any]:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
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
        if not pending:
            raise HTTPException(status_code=403, detail="Invite not found or expired")
        if pending.get("used"):
            raise HTTPException(status_code=403, detail="Invite already used")
        key_doc = verify_peer_domain(cfg.server_name, matrix_server or None)
        add_trusted_domain(redeemer, sync=False)
        add_pending(
            pending_path,
            payload["nonce"],
            {**pending, "used": True, "redeemer_domain": redeemer},
        )
        schedule_federation_sync()
        return JSONResponse(
            {
                "issuer_domain": cfg.server_name,
                "matrix_server": matrix_server or cfg.server_name,
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
            verify_resp = post_json(
                verify_url,
                {"token": token, "redeemer_domain": cfg.server_name},
            )
            if not verify_resp.get("matrix_server_key"):
                peer_host = verify_resp.get("matrix_server") or issuer
                verify_peer_domain(peer_host, None)
            add_trusted_domain(issuer, sync=True)
            message = f"Linked with {issuer}. Federation allowlist sync requested."
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code == 403 and "already used" in body.lower():
                message = "This invite was already used. Ask the other household to create a new invite."
            else:
                message = f"Peer rejected the invite (HTTP {exc.code}): {body[:200]}"
        except (urllib.error.URLError, OSError) as exc:
            message = f"Could not reach peer at {verify_url}: {exc}"
        return TEMPLATES.TemplateResponse(
            request,
            "invite_redeem.html",
            {"user": user, "csrf": csrf_token(request), "token": token, "message": message},
        )

    def member_role(username: str) -> str | None:
        if username in list_group_members(cfg.parents_group, cfg.yunohost_cli):
            return "parent"
        if username in list_group_members(cfg.kids_group, cfg.yunohost_cli):
            return "kid"
        return None

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
                "events_url": cfg.events_base_url,
                "member_count": len(list_members(cfg)),
            },
        )

    @app.get("/members", response_class=HTMLResponse)
    async def members_list(request: Request, user: str = Depends(current_user)):
        return TEMPLATES.TemplateResponse(
            request,
            "members.html",
            {"user": user, "members": list_members(cfg), "message": request.query_params.get("msg", "")},
        )

    @app.get("/members/add", response_class=HTMLResponse)
    async def members_add_form(request: Request, user: str = Depends(current_user)):
        return TEMPLATES.TemplateResponse(
            request,
            "member_add.html",
            {"user": user, "csrf": csrf_token(request), "error": ""},
        )

    @app.post("/members/add")
    async def members_add_submit(
        request: Request,
        user: str = Depends(current_user),
        csrf: str = Form(...),
        username: str = Form(...),
        full_name: str = Form(...),
        role: str = Form(...),
    ):
        verify_csrf(request, csrf)
        try:
            uname = validate_username(username)
            if role not in ("parent", "kid"):
                raise ValueError("Role must be parent or kid")
            password = generate_password()
            create_member(uname, full_name.strip(), role, cfg.server_name, password)
        except ValueError as exc:
            return TEMPLATES.TemplateResponse(
                request,
                "member_add.html",
                {"user": user, "csrf": csrf_token(request), "error": str(exc)},
            )
        return TEMPLATES.TemplateResponse(
            request,
            "member_created.html",
            {
                "username": uname,
                "password": password,
                "role": role,
                "server_name": cfg.server_name,
            },
        )

    @app.get("/members/{username}", response_class=HTMLResponse)
    async def member_detail(request: Request, username: str, user: str = Depends(current_user)):
        role = member_role(username)
        if not role:
            raise HTTPException(status_code=404, detail="Not a family member")
        st = synapse_user_status(username, cfg.server_name)
        return TEMPLATES.TemplateResponse(
            request,
            "member_detail.html",
            {
                "username": username,
                "role": role,
                "mxid": f"@{username}:{cfg.server_name}",
                "matrix_label": matrix_status_label(st),
                "csrf": csrf_token(request),
                "new_password": "",
            },
        )

    @app.post("/members/{username}/reset-password")
    async def member_reset_password(
        request: Request,
        username: str,
        user: str = Depends(current_user),
        csrf: str = Form(...),
    ):
        verify_csrf(request, csrf)
        if not member_role(username):
            raise HTTPException(status_code=404, detail="Not a family member")
        pw = generate_password()
        reset_password(username, pw)
        role = member_role(username)
        st = synapse_user_status(username, cfg.server_name)
        return TEMPLATES.TemplateResponse(
            request,
            "member_detail.html",
            {
                "username": username,
                "role": role,
                "mxid": f"@{username}:{cfg.server_name}",
                "matrix_label": matrix_status_label(st),
                "csrf": csrf_token(request),
                "new_password": pw,
            },
        )

    @app.post("/members/{username}/remove")
    async def member_remove(
        request: Request,
        username: str,
        user: str = Depends(current_user),
        csrf: str = Form(...),
    ):
        verify_csrf(request, csrf)
        if username == user:
            raise HTTPException(status_code=400, detail="You cannot remove your own account here")
        if not member_role(username):
            raise HTTPException(status_code=404, detail="Not a family member")
        result = delete_member(username)
        msg = "Member+removed"
        if result.get("matrix_deactivated") == "0":
            msg = "Member+removed+but+Matrix+deactivation+failed"
        return RedirectResponse(url=dash_url(f"/members?msg={msg}", root_path), status_code=303)

    @app.get("/members/{username}/location", response_class=HTMLResponse)
    async def member_location_page(request: Request, username: str, user: str = Depends(current_user)):
        if member_role(username) != "kid":
            raise HTTPException(status_code=404, detail="Location setup is for child accounts")
        stored = load_stored_credentials(cfg.owntracks_store_path, username)
        return TEMPLATES.TemplateResponse(
            request,
            "member_location.html",
            {
                "username": username,
                "csrf": csrf_token(request),
                "has_config": bool(stored),
                "location_url": cfg.location_base_url,
            },
        )

    @app.post("/members/{username}/location")
    async def member_location_issue(
        request: Request,
        username: str,
        user: str = Depends(current_user),
        csrf: str = Form(...),
        regenerate: str = Form(""),
    ):
        verify_csrf(request, csrf)
        if member_role(username) != "kid":
            raise HTTPException(status_code=404, detail="Location setup is for child accounts")
        loc_domain = cfg.location_domain or cfg.location_base_url.replace("https://", "").split("/")[0]
        issue_owntracks(username, cfg.server_name, loc_domain)
        return RedirectResponse(url=dash_url(f"/members/{username}/location", root_path), status_code=303)

    @app.get("/calendar", response_class=HTMLResponse)
    async def calendar_setup_page(request: Request, user: str = Depends(current_user)):
        if not cfg.caldav_root:
            raise HTTPException(status_code=503, detail="Calendar not configured on this node")
        return TEMPLATES.TemplateResponse(
            request,
            "calendar.html",
            {
                "user": user,
                "caldav_root": cfg.caldav_root.rstrip("/"),
                "principal_url": caldav_account_url(cfg.caldav_root, user),
                "qr_url": dash_url("/calendar/qr.png", root_path),
            },
        )

    @app.get("/calendar/qr.png")
    async def calendar_setup_qr(user: str = Depends(current_user)):
        if not cfg.caldav_root:
            raise HTTPException(status_code=503, detail="Calendar not configured")
        import io

        import qrcode

        hint = davx5_login_hint(cfg.caldav_root, user)
        img = qrcode.make(hint)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return Response(content=buf.getvalue(), media_type="image/png")

    @app.get("/members/{username}/location/qr.png")
    async def member_location_qr(username: str, user: str = Depends(current_user)):
        if member_role(username) != "kid":
            raise HTTPException(status_code=404, detail="Not found")
        stored = load_stored_credentials(cfg.owntracks_store_path, username)
        if not stored:
            raise HTTPException(status_code=404, detail="No location setup yet")
        cfg_json = build_owntracks_config(
            stored.get("publish_url", cfg.location_base_url),
            stored.get("username", username),
            stored.get("password", ""),
            stored.get("device_id", f"{username}-phone"),
            stored.get("tracker_id", username[:2]),
        )
        link = owntracks_otcp_link(cfg_json)
        import io

        import qrcode

        img = qrcode.make(link)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return Response(content=buf.getvalue(), media_type="image/png")

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
                "events_enabled": entry.get("events_enabled", True),
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
        events_enabled: str = Form("0"),
        events_rules_form: str = Form(""),
    ):
        verify_csrf(request, csrf)
        policy = refreshed_policy()
        if kid_mxid not in (policy.get("kids") or {}):
            raise HTTPException(status_code=404, detail="Unknown kid")
        prev_entry = dict((policy.get("kids") or {}).get(kid_mxid) or {})
        mxids = [ln.strip() for ln in allowlist_mxids.splitlines() if ln.strip()]
        domains = [ln.strip() for ln in allowlist_domains.splitlines() if ln.strip()]
        entry: Dict[str, Any] = {
            "allowlist_mxids": mxids,
            "allowlist_domains": domains,
        }
        if events_rules_form == "1":
            entry["events_enabled"] = events_enabled in ("1", "on", "true", "yes")
        else:
            entry["events_enabled"] = prev_entry.get("events_enabled", True)
        if qh_start and qh_end:
            entry["quiet_hours"] = {
                "start": qh_start,
                "end": qh_end,
                "timezone": qh_timezone or "UTC",
                "days": list(range(7)),
            }
        policy["kids"][kid_mxid] = entry
        save_policy(policy_path, policy)
        if events_perms_cmd:
            subprocess.run(events_perms_cmd.split(), check=False, timeout=120)
        return RedirectResponse(url=dash_url("/", root_path), status_code=303)

    app.include_router(create_permissions_router(cfg))
    return app


app = create_app()
