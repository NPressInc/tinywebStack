"""TinyWeb mobile app JSON API (enrollment, devices, members)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from tinywebstack_dashboard.app_devices import (
    clear_enroll_failures,
    consume_enroll_code,
    count_devices_for_user,
    create_device,
    create_enroll_code,
    enroll_rate_limited,
    get_device,
    list_all_devices,
    list_devices_for_user,
    mint_device_token,
    record_enroll_failure,
    revoke_device,
)
from tinywebstack_dashboard.auth import (
    DashboardConfig,
    api_user,
    list_group_members,
    require_parent_user,
    user_in_group,
)
from tinywebstack_dashboard.invite_store import load_pending
from tinywebstack_dashboard.members import list_members
from tinywebstack_dashboard.peer_verify import _ssl_context
from tinywebstack_dashboard.yunohost_actions import (
    issue_owntracks,
    matrix_device_delete,
    nextcloud_app_password,
    nextcloud_app_password_delete,
)
from tinywebstack_family.policy import QuietHours

Platform = Literal["android", "ios", "other"]


def _no_store(data: Any, status: int = 200) -> JSONResponse:
    return JSONResponse(data, status_code=status, headers={"Cache-Control": "no-store"})


def _client_ip(request: Request) -> str:
    real = request.headers.get("X-Real-IP", "").strip()
    if real:
        return real
    if request.client:
        return request.client.host
    return "unknown"


def _matrix_homeserver_url(matrix_server: str, server_name: str) -> str:
    host = (matrix_server or server_name).strip()
    if host.startswith("http://") or host.startswith("https://"):
        return host.rstrip("/")
    return f"https://{host}"


def _mobilizon_login(events_base: str, username: str, server_name: str, password: str) -> Dict[str, Any]:
    if not events_base.strip():
        return {"status": "unavailable"}
    base = events_base.rstrip("/")
    api_url = f"{base}/api"
    for email in (f"{username}@{server_name}", username):
        body = {
            "query": (
                "mutation Login($email: String!, $password: String!) {"
                " login(email: $email, password: $password) { accessToken refreshToken }"
                "}"
            ),
            "variables": {"email": email, "password": password},
        }
        try:
            data = json.dumps(body).encode("utf-8")
            req = urllib.request.Request(
                api_url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=20, context=_ssl_context()) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            login = (payload.get("data") or {}).get("login") or {}
            token = login.get("accessToken")
            if token:
                out: Dict[str, Any] = {
                    "status": "ok",
                    "access_token": token,
                }
                if login.get("refreshToken"):
                    out["refresh_token"] = login["refreshToken"]
                return out
        except (urllib.error.URLError, OSError, json.JSONDecodeError, urllib.error.HTTPError):
            continue
    return {"status": "unavailable"}


def _matrix_password_login(
    homeserver_url: str,
    username: str,
    server_name: str,
    password: str,
    device_name: str,
) -> Dict[str, Any]:
    url = f"{homeserver_url.rstrip('/')}/_matrix/client/v3/login"
    body = {
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": username},
        "password": password,
        "initial_device_display_name": f"TinyWeb {device_name}",
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=25, context=_ssl_context()) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError:
        return {"_auth_error": True}
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=503, detail="Matrix login unavailable") from exc
    return {
        "status": "ok",
        "access_token": payload.get("access_token"),
        "device_id": payload.get("device_id"),
        "user_id": payload.get("user_id"),
        "homeserver": homeserver_url.rstrip("/"),
    }


def _quiet_hours_payload(
    username: str,
    role: str,
    server_name: str,
    when: Optional[datetime] = None,
) -> Dict[str, Any]:
    if role == "parent":
        return {"configured": False, "active": False, "window": None}
    from tinywebstack_permissions.store import PermissionsDB, get_db_path

    path = get_db_path()
    if not path.is_file():
        return {"configured": False, "active": False, "window": None}
    with PermissionsDB(path) as db:
        ps = db.get_permissions(username)
        if ps is None or not ps.quiet_hours:
            return {"configured": False, "active": False, "window": None}
        qh = ps.quiet_hours
        window = {
            "start": qh.start,
            "end": qh.end,
            "timezone": qh.timezone,
            "days": list(qh.days),
        }
        quiet = QuietHours(
            start=qh.start,
            end=qh.end,
            timezone=qh.timezone,
            days=list(qh.days),
        )
        active = quiet.is_active(when)
        return {
            "configured": True,
            "active": active,
            "window": window,
            "timezone": qh.timezone,
        }


def _events_enabled(username: str, role: str) -> bool:
    if role == "parent":
        return True
    from tinywebstack_permissions.store import PermissionsDB, get_db_path

    path = get_db_path()
    if not path.is_file():
        return True
    with PermissionsDB(path) as db:
        ps = db.get_permissions(username)
        if ps is None:
            return True
        return bool(ps.events_enabled)


class CodeCreateBody(BaseModel):
    username: str


class EnrollBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    method: Literal["password", "code"]
    username: Optional[str] = None
    password: Optional[str] = None
    code: Optional[str] = None
    device_name: str = Field(min_length=1, max_length=64)
    platform: Platform


def create_app_api_router(
    cfg: DashboardConfig,
    *,
    matrix_server: str,
    pending_invites_path: str,
) -> APIRouter:
    router = APIRouter(tags=["app"])

    def member_role(username: str) -> str | None:
        if user_in_group(username, cfg.parents_group, cfg.yunohost_cli):
            return "parent"
        if user_in_group(username, cfg.kids_group, cfg.yunohost_cli):
            return "kid"
        return None

    def homeserver_url() -> str:
        return _matrix_homeserver_url(matrix_server, cfg.server_name)

    @router.post("/api/app/codes")
    async def create_code(body: CodeCreateBody, request: Request):
        parent = require_parent_user(api_user(request, cfg), cfg)
        target = body.username.strip().lower()
        if not member_role(target):
            raise HTTPException(status_code=404, detail="Not a family member")
        code, expires_at = create_enroll_code(target, parent)
        qr_payload = f"tinyweb://enroll?server={cfg.server_name}&code={code}"
        return _no_store({"code": code, "expires_at": expires_at, "qr_payload": qr_payload})

    @router.post("/api/app/enroll")
    async def app_enroll(body: EnrollBody, request: Request):
        ip = _client_ip(request)
        method = body.method
        username = (body.username or "").strip().lower() if body.username else ""

        if method == "code":
            code = (body.code or "").strip().upper()
            if not code:
                record_enroll_failure(ip, "unknown")
                return _no_store({"error": "invalid_credentials"}, status=401)
            if enroll_rate_limited(ip, f"code:{code}"):
                raise HTTPException(status_code=429, detail="Too many attempts")
            resolved = consume_enroll_code(code)
            if not resolved:
                record_enroll_failure(ip, f"code:{code}")
                return _no_store({"error": "invalid_credentials"}, status=401)
            username = resolved
            clear_enroll_failures(ip, username)
        else:
            if not username or not body.password:
                record_enroll_failure(ip, username or "unknown")
                return _no_store({"error": "invalid_credentials"}, status=401)
            if enroll_rate_limited(ip, username):
                raise HTTPException(status_code=429, detail="Too many attempts")

        role = member_role(username)
        if not role:
            raise HTTPException(status_code=403, detail="Not a family member")

        mxid = f"@{username}:{cfg.server_name}"
        matrix_section: Dict[str, Any]
        mobilizon_section: Dict[str, Any]
        matrix_device_id: Optional[str] = None

        if method == "password":
            matrix_section = _matrix_password_login(
                homeserver_url(),
                username,
                cfg.server_name,
                body.password or "",
                body.device_name,
            )
            if matrix_section.get("_auth_error"):
                record_enroll_failure(ip, username)
                return _no_store({"error": "invalid_credentials"}, status=401)
            matrix_device_id = matrix_section.get("device_id")
            clear_enroll_failures(ip, username)
            events_url = cfg.events_base_url or os.environ.get("TWS_EVENTS_URL", "")
            mobilizon_section = _mobilizon_login(
                events_url, username, cfg.server_name, body.password or ""
            )
        else:
            matrix_section = {
                "status": "not_provisioned",
                "reason": "code enrollment gets Matrix in Stage 2; use Element X",
            }
            mobilizon_section = {"status": "password_required"}

        nc_name = f"TinyWeb {body.device_name}"[:64]
        nc_token_name: Optional[str] = None
        nc_token_id: Optional[str] = None
        try:
            nc = nextcloud_app_password(username, nc_name)
            caldav_section: Dict[str, Any] = {
                "root": cfg.caldav_root.rstrip("/") if cfg.caldav_root else "",
                "username": username,
                "password": nc.get("password", ""),
            }
            nc_token_name = nc.get("name", nc_name)
            nc_token_id = nc.get("token_id")
        except Exception:
            caldav_section = {"status": "unavailable"}

        if role == "kid":
            loc_domain = cfg.location_domain or (
                cfg.location_base_url.replace("https://", "").split("/")[0]
                if cfg.location_base_url
                else cfg.server_name
            )
            try:
                ot = issue_owntracks(username, cfg.server_name, loc_domain)
                owntracks_section: Dict[str, Any] = {
                    "url": ot.get("url", ""),
                    "username": ot.get("user", username),
                    "device": ot.get("device", ""),
                    "password": ot.get("password", ""),
                    "tid": ot.get("tid", ""),
                }
            except Exception:
                owntracks_section = {"status": "unavailable"}
        else:
            owntracks_section = {"status": "not_needed"}

        token = mint_device_token()
        device = create_device(
            username=username,
            role=role,
            device_name=body.device_name,
            platform=body.platform,
            token=token,
            matrix_device_id=matrix_device_id,
            nextcloud_token_name=nc_token_name,
            nextcloud_token_id=nc_token_id,
        )

        return _no_store(
            {
                "device_id": device.id,
                "username": username,
                "role": role,
                "mxid": mxid,
                "server_name": cfg.server_name,
                "dashboard": {"token": token, "api_base": "/family/api"},
                "matrix": matrix_section,
                "caldav": caldav_section,
                "mobilizon": mobilizon_section,
                "owntracks": owntracks_section,
            }
        )

    @router.get("/api/app/me")
    async def app_me(request: Request):
        auth = api_user(request, cfg)
        role = member_role(auth.username)
        if not role:
            raise HTTPException(status_code=403, detail="Not a family member")
        when = None
        qh_env = os.environ.get("TWS_APP_QUIET_HOURS_NOW")
        if qh_env:
            when = datetime.fromisoformat(qh_env)
            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)
        return _no_store(
            {
                "username": auth.username,
                "role": role,
                "mxid": f"@{auth.username}:{cfg.server_name}",
                "quiet_hours": _quiet_hours_payload(auth.username, role, cfg.server_name, when),
                "events_enabled": _events_enabled(auth.username, role),
            }
        )

    @router.get("/api/app/devices")
    async def app_devices_list(request: Request):
        auth = api_user(request, cfg)
        if user_in_group(auth.username, cfg.parents_group, cfg.yunohost_cli):
            devices = list_all_devices()
        else:
            devices = list_devices_for_user(auth.username)
        return _no_store([d.to_public_dict() for d in devices])

    @router.post("/api/app/devices/{device_id}/revoke")
    async def app_device_revoke(device_id: str, request: Request):
        auth = api_user(request, cfg)
        dev = get_device(device_id)
        if not dev or dev.revoked_at:
            raise HTTPException(status_code=404, detail="Device not found")
        is_parent = user_in_group(auth.username, cfg.parents_group, cfg.yunohost_cli)
        if not is_parent and dev.username != auth.username:
            raise HTTPException(status_code=403, detail="Forbidden")
        revoked = revoke_device(device_id)
        if not revoked:
            raise HTTPException(status_code=404, detail="Device not found")
        matrix_revoked = False
        nc_revoked = False
        if revoked.matrix_device_id:
            try:
                matrix_device_delete(revoked.username, cfg.server_name, revoked.matrix_device_id)
                matrix_revoked = True
            except Exception:
                pass
        if revoked.nextcloud_token_id:
            try:
                nextcloud_app_password_delete(revoked.username, revoked.nextcloud_token_id)
                nc_revoked = True
            except Exception:
                pass
        out = revoked.to_public_dict()
        out["matrix_device_deleted"] = matrix_revoked
        out["nextcloud_token_deleted"] = nc_revoked
        return _no_store(out)

    @router.get("/api/members")
    async def api_members(request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        rows = []
        for m in list_members(cfg):
            rows.append(
                {
                    "username": m.username,
                    "role": m.role,
                    "mxid": m.mxid,
                    "matrix_label": m.matrix_label,
                    "device_count": count_devices_for_user(m.username),
                }
            )
        return _no_store(rows)

    @router.get("/api/invites")
    async def api_invites(request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        from pathlib import Path

        pending = load_pending(Path(pending_invites_path))
        invites: List[Dict[str, Any]] = []
        for nonce, meta in (pending.get("invites") or {}).items():
            if meta.get("used"):
                continue
            invites.append(
                {
                    "nonce": nonce,
                    "created_by": meta.get("created_by"),
                    "issuer": meta.get("issuer"),
                    "redeemer_domain": meta.get("redeemer_domain"),
                }
            )
        return _no_store(invites)

    return router


def revoke_user_devices(username: str, server_name: str) -> None:
    """Revoke all app devices for a user (e.g. password reset). Best-effort cleanup."""
    from tinywebstack_dashboard.app_devices import revoke_all_for_user

    for dev in revoke_all_for_user(username):
        if dev.matrix_device_id:
            try:
                matrix_device_delete(dev.username, server_name, dev.matrix_device_id)
            except Exception:
                pass
        if dev.nextcloud_token_id:
            try:
                nextcloud_app_password_delete(dev.username, dev.nextcloud_token_id)
            except Exception:
                pass
