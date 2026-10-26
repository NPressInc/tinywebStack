"""TinyWeb mobile app JSON API (enrollment, devices, members)."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Literal, Optional, Tuple

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
from tinywebstack_dashboard.map_assets import mint_map_assets_token
from tinywebstack_dashboard.map_config import load_map_config
from tinywebstack_dashboard.push_config import enroll_push_section
from tinywebstack_dashboard.invite_store import load_pending
from tinywebstack_dashboard.link_invite import (
    LinkInviteError,
    decline_link_invite_remote,
    linked_families_payload,
    preview_link_invite,
    redeem_link_invite,
)
from tinywebstack_dashboard.member_ops import (
    create_family_member,
    create_pending_family_invite,
    delete_pending_family_invite,
    issue_member_enroll_code,
    list_member_devices_public,
    member_role as ops_member_role,
    remove_family_member,
    reset_member_password,
    revoke_member_app_device,
)
from tinywebstack_dashboard.federation import (
    read_nodes_conf,
    reconcile_state_with_policy,
    state_path_from_env,
)
from tinywebstack_dashboard.members import list_members
from tinywebstack_dashboard.policy_store import load_policy
from tinywebstack_dashboard.owntracks_recorder import (
    fetch_all_last,
    fetch_track,
    latest_per_kid,
    track_points,
)
from tinywebstack_dashboard.owntracks_setup import load_stored_credentials
from tinywebstack_dashboard.peer_verify import _ssl_context
from tinywebstack_dashboard.yunohost_actions import (
    issue_owntracks,
    matrix_device_delete,
    nextcloud_app_password,
    nextcloud_app_password_delete,
)
from tinywebstack_family.login_ticket import make_ticket
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
                    "events_url": base,
                    "api_url": api_url,
                    "access_token": token,
                }
                if login.get("refreshToken"):
                    out["refresh_token"] = login["refreshToken"]
                return out
        except (urllib.error.URLError, OSError, json.JSONDecodeError, urllib.error.HTTPError):
            continue
    return {"status": "unavailable"}


def _load_matrix_login_ticket_secret() -> Optional[bytes]:
    path = os.environ.get("TWS_MATRIX_LOGIN_TICKET_SECRET_FILE", "").strip()
    if not path:
        return None
    try:
        data = Path(path).read_bytes()
    except OSError:
        return None
    data = data.strip(b"\n\r")
    return data if data else None


def _matrix_login_ticket_login(
    homeserver_url: str,
    username: str,
    device_name: str,
) -> Dict[str, Any]:
    secret = _load_matrix_login_ticket_secret()
    if not secret:
        return {"status": "unavailable"}
    ticket = make_ticket(secret, username, int(time.time()))
    url = f"{homeserver_url.rstrip('/')}/_matrix/client/v3/login"
    body = {
        "type": "org.tinywebstack.login_ticket",
        "identifier": {"type": "m.id.user", "user": username},
        "ticket": ticket,
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
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, json.JSONDecodeError):
        return {"status": "unavailable"}
    access_token = payload.get("access_token")
    device_id = payload.get("device_id")
    if not access_token or not device_id:
        return {"status": "unavailable"}
    return {
        "status": "ok",
        "access_token": access_token,
        "device_id": device_id,
        "user_id": payload.get("user_id"),
        "homeserver": homeserver_url.rstrip("/"),
    }


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
    except urllib.error.HTTPError as exc:
        if exc.code == 429:
            # Synapse rc_login throttling is not a bad password; don't count it as a failure.
            retry_s = 60
            try:
                retry_s = max(1, int(json.loads(exc.read().decode("utf-8")).get("retry_after_ms", 60000) / 1000))
            except (ValueError, OSError, AttributeError, TypeError):
                pass
            return {"_rate_limited": True, "retry_after": retry_s}
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


def _kid_owntracks_section(section: Dict[str, Any]) -> Dict[str, Any]:
    """Kids get HTTP publish credentials; parents do not publish from the app."""
    if section.get("status") in ("unavailable", "not_needed"):
        return section
    return {**section, "publish": True, "mode": "http"}


def _kid_tid_map(cfg: DashboardConfig) -> Dict[str, str]:
    kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
    out: Dict[str, str] = {}
    for username in kids:
        stored = load_stored_credentials(cfg.owntracks_store_path, username)
        if stored and stored.get("tracker_id"):
            out[username] = str(stored["tracker_id"])
    return out


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


def _chat_contacts_for_user(
    cfg: DashboardConfig, username: str, role: str
) -> List[Dict[str, str]]:
    parents = list_group_members(cfg.parents_group, cfg.yunohost_cli)
    kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
    server = cfg.server_name
    self_mxid = f"@{username}:{server}"
    out: List[Dict[str, str]] = []
    seen_mxids: set[str] = set()

    def append_contact(entry: Dict[str, str]) -> None:
        mxid = entry["mxid"]
        if mxid in seen_mxids:
            return
        seen_mxids.add(mxid)
        out.append(entry)

    def local_entry(u: str, contact_role: str) -> Dict[str, str]:
        return {
            "username": u,
            "mxid": f"@{u}:{server}",
            "display_name": u,
            "role": contact_role,
        }

    if role == "parent":
        for u in parents:
            if u != username:
                append_contact(local_entry(u, "parent"))
        for u in kids:
            if u != username:
                append_contact(local_entry(u, "kid"))
        return out

    for u in parents:
        if u != username:
            append_contact(local_entry(u, "parent"))

    from tinywebstack_permissions.store import PermissionsDB, get_db_path

    db_path = get_db_path()
    if db_path.is_file():
        with PermissionsDB(db_path) as db:
            ps = db.get_permissions(username)
            if ps is not None:
                allowlist_mxids = set(ps.allowlist_mxids)
                allowlist_domains = set(ps.allowlist_domains)
            else:
                allowlist_mxids = set()
                allowlist_domains = set()
    else:
        policy = load_policy(Path(cfg.policy_path))
        kid_entry = (policy.get("kids") or {}).get(self_mxid) or {}
        allowlist_mxids = {
            str(x).strip() for x in kid_entry.get("allowlist_mxids", []) if x
        }
        allowlist_domains = {
            str(x).strip() for x in kid_entry.get("allowlist_domains", []) if x
        }

    if server in allowlist_domains:
        for u in kids:
            if u != username:
                append_contact(local_entry(u, "kid"))

    for mxid in sorted(allowlist_mxids):
        if not mxid or mxid == self_mxid or mxid in seen_mxids:
            continue
        if not (mxid.startswith("@") and ":" in mxid):
            continue
        localpart, domain = mxid[1:].split(":", 1)
        if domain == server and localpart in parents:
            contact_role = "parent"
        elif domain == server and localpart in kids:
            contact_role = "kid"
        else:
            contact_role = "contact"
        append_contact(
            {
                "username": localpart,
                "mxid": mxid,
                "display_name": localpart,
                "role": contact_role,
            }
        )

    return out


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


class MemberCreateBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str
    role: Literal["parent", "kid"]
    display_name: Optional[str] = None
    issue_enroll_code: bool = False


class LinkInviteTokenBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str = Field(min_length=1)


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
    trusted_domains: Callable[[], List[str]],
    add_trusted_domain: Callable[[str], None],
    run_federation_sync: Callable[[], Tuple[str, str]],
    decline_remote_invite: Callable[[str, str], None] = decline_link_invite_remote,
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
            role = member_role(username)
            if not role:
                raise HTTPException(status_code=403, detail="Not a family member")
            matrix_section = _matrix_login_ticket_login(
                homeserver_url(),
                username,
                body.device_name,
            )
            matrix_device_id = (
                matrix_section.get("device_id")
                if matrix_section.get("status") == "ok"
                else None
            )
            mobilizon_section = {"status": "password_required"}
        else:
            if not username or not body.password:
                record_enroll_failure(ip, username or "unknown")
                return _no_store({"error": "invalid_credentials"}, status=401)
            if enroll_rate_limited(ip, username):
                raise HTTPException(status_code=429, detail="Too many attempts")
            matrix_section = _matrix_password_login(
                homeserver_url(),
                username,
                cfg.server_name,
                body.password or "",
                body.device_name,
            )
            if matrix_section.get("_rate_limited"):
                return JSONResponse(
                    {"error": "rate_limited", "retry_after": matrix_section["retry_after"]},
                    status_code=429,
                    headers={"Retry-After": str(matrix_section["retry_after"]), "Cache-Control": "no-store"},
                )
            if matrix_section.get("_auth_error"):
                record_enroll_failure(ip, username)
                return _no_store({"error": "invalid_credentials"}, status=401)
            matrix_device_id = matrix_section.get("device_id")
            role = member_role(username)
            if not role:
                if matrix_device_id:
                    try:
                        matrix_device_delete(username, cfg.server_name, matrix_device_id)
                    except Exception:
                        pass
                raise HTTPException(status_code=403, detail="Not a family member")
            clear_enroll_failures(ip, username)
            events_url = cfg.events_base_url or os.environ.get("TWS_EVENTS_URL", "")
            mobilizon_section = _mobilizon_login(
                events_url, username, cfg.server_name, body.password or ""
            )

        mxid = f"@{username}:{cfg.server_name}"

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
            stored_ot = load_stored_credentials(cfg.owntracks_store_path, username)
            if stored_ot:
                owntracks_section: Dict[str, Any] = {
                    "url": stored_ot.get("publish_url", ""),
                    "username": stored_ot.get("username", username),
                    "device": stored_ot.get("device_id", ""),
                    "password": stored_ot.get("password", ""),
                    "tid": stored_ot.get("tracker_id", ""),
                }
            else:
                try:
                    ot = issue_owntracks(username, cfg.server_name, loc_domain)
                    owntracks_section = {
                        "url": ot.get("url", ""),
                        "username": ot.get("user", username),
                        "device": ot.get("device", ""),
                        "password": ot.get("password", ""),
                        "tid": ot.get("tid", ""),
                    }
                except Exception:
                    owntracks_section = {"status": "unavailable"}
            owntracks_section = _kid_owntracks_section(owntracks_section)
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

        payload: Dict[str, Any] = {
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
        push_section = enroll_push_section(cfg.server_name)
        if push_section:
            payload["push"] = push_section
        return _no_store(payload)

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
                "chat_contacts": _chat_contacts_for_user(cfg, auth.username, role),
            }
        )

    @router.get("/api/app/contacts")
    async def app_contacts(request: Request):
        auth = api_user(request, cfg)
        role = member_role(auth.username)
        if not role:
            raise HTTPException(status_code=403, detail="Not a family member")
        return _no_store(
            {"contacts": _chat_contacts_for_user(cfg, auth.username, role)}
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

    @router.get("/api/map")
    async def api_map(request: Request):
        """Parent-only: self-hosted basemap URLs and bounds (kids cannot load the family region)."""
        auth = api_user(request, cfg)
        require_parent_user(auth, cfg)
        import os

        public_base = (os.environ.get("TWS_PUBLIC_BASE_URL") or "").rstrip("/")
        if not public_base:
            public_base = f"https://{cfg.server_name}" if cfg.server_name else "https://localhost"
        map_cfg = load_map_config()
        assets_query, _ = mint_map_assets_token(auth.username)
        return _no_store(map_cfg.to_api_dict(public_base, assets_query))

    @router.get("/api/locations")
    async def api_locations(request: Request):
        """Parent-only: latest Recorder position per kid (kids cannot read the map)."""
        require_parent_user(api_user(request, cfg), cfg)
        kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
        rows, ok = fetch_all_last()
        if not ok or rows is None:
            return _no_store({"kids": [], "status": "unavailable"})
        tid_map = _kid_tid_map(cfg)
        return _no_store({"kids": latest_per_kid(kids, rows, tid_map)})

    @router.get("/api/locations/{username}/track")
    async def api_location_track(username: str, request: Request, hours: int = 24):
        """Parent-only track history for one kid (Recorder /api/0/locations, capped at 2000 points)."""
        require_parent_user(api_user(request, cfg), cfg)
        kid = username.strip().lower()
        kids = list_group_members(cfg.kids_group, cfg.yunohost_cli)
        if kid not in kids:
            raise HTTPException(status_code=404, detail="Not a kid account")
        stored = load_stored_credentials(cfg.owntracks_store_path, kid)
        device = (stored or {}).get("device_id") or ""
        if not device:
            raise HTTPException(status_code=404, detail="No location device for user")
        rows, ok = fetch_track(kid, device, hours)
        if not ok or rows is None:
            return _no_store({"username": kid, "hours": hours, "points": [], "status": "unavailable"})
        return _no_store(
            {
                "username": kid,
                "display_name": kid,
                "hours": max(1, min(hours, 168)),
                "points": track_points(rows),
            }
        )

    @router.get("/api/federation")
    async def api_federation(request: Request):
        """Parent-only: trusted domains and linked peer nodes for allowlist UI."""
        require_parent_user(api_user(request, cfg), cfg)
        state_file = state_path_from_env()
        policy_file = Path(cfg.policy_path)
        domains = reconcile_state_with_policy(
            state_file,
            policy_file,
            server_name=cfg.server_name,
            include_synapse_snippet=False,
            read_only=True,
        )
        nodes_conf = Path(os.environ.get("TWS_NODES_CONF", "/etc/tinywebstack/nodes.conf"))
        peer_nodes = [n for n in read_nodes_conf(nodes_conf) if n["domain"] != cfg.server_name]
        return _no_store(
            {
                "trusted_domains": sorted(set(domains)),
                "peer_nodes": peer_nodes,
            }
        )

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

    @router.post("/api/members")
    async def api_members_create(body: MemberCreateBody, request: Request):
        parent = require_parent_user(api_user(request, cfg), cfg)
        result = create_family_member(
            cfg,
            username=body.username,
            role=body.role,
            display_name=body.display_name,
            issue_enroll_code=body.issue_enroll_code,
            enroll_issued_by=parent,
        )
        payload: Dict[str, Any] = {
            "username": result.username,
            "role": result.role,
            "password": result.password,
        }
        if result.enroll_code:
            payload["enroll_code"] = result.enroll_code
            payload["enroll_expires_at"] = result.enroll_expires_at
            payload["enroll_qr_payload"] = result.enroll_qr_payload
        return _no_store(payload)

    @router.post("/api/members/{username}/reset-password")
    async def api_members_reset_password(username: str, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        password = reset_member_password(cfg, username.strip().lower())
        return _no_store({"username": username.strip().lower(), "password": password})

    @router.delete("/api/members/{username}")
    async def api_members_delete(username: str, request: Request):
        auth = api_user(request, cfg)
        parent = require_parent_user(auth, cfg)
        result = remove_family_member(cfg, parent, username.strip().lower())
        return _no_store({"username": username.strip().lower(), "result": result})

    @router.post("/api/members/{username}/enroll-code")
    async def api_members_enroll_code(username: str, request: Request):
        parent = require_parent_user(api_user(request, cfg), cfg)
        payload = issue_member_enroll_code(cfg, username.strip().lower(), parent)
        return _no_store(payload)

    @router.get("/api/members/{username}/devices")
    async def api_members_devices(username: str, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        target = username.strip().lower()
        if not ops_member_role(cfg, target):
            raise HTTPException(status_code=404, detail="Not a family member")
        return _no_store(list_member_devices_public(target))

    @router.post("/api/members/{username}/devices/{device_id}/revoke")
    async def api_members_device_revoke(username: str, device_id: str, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        revoke_member_app_device(cfg, username.strip().lower(), device_id)
        return _no_store({"revoked": device_id})

    @router.post("/api/invites")
    async def api_invites_create(request: Request):
        parent = require_parent_user(api_user(request, cfg), cfg)
        secret = os.environ.get("TWS_INVITE_SECRET", "").strip()
        if not secret:
            raise HTTPException(status_code=500, detail="TWS_INVITE_SECRET not configured")
        public_base = os.environ.get(
            "TWS_PUBLIC_BASE_URL", f"https://{cfg.server_name}/family"
        )
        payload = create_pending_family_invite(
            server_name=cfg.server_name,
            invite_secret=secret,
            pending_path=Path(pending_invites_path),
            created_by=parent,
            public_base_url=public_base,
        )
        return _no_store(payload)

    @router.delete("/api/invites/{nonce}")
    async def api_invites_delete(nonce: str, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        delete_pending_family_invite(Path(pending_invites_path), nonce)
        return _no_store({"deleted": nonce})

    @router.post("/api/link-invites/preview")
    async def api_link_invites_preview(body: LinkInviteTokenBody, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        try:
            payload = preview_link_invite(
                body.token,
                own_domain=cfg.server_name,
                trusted_domains=trusted_domains(),
            )
        except LinkInviteError as exc:
            raise HTTPException(status_code=exc.status, detail=exc.detail) from exc
        return _no_store(payload)

    @router.post("/api/link-invites/accept")
    async def api_link_invites_accept(body: LinkInviteTokenBody, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        try:
            result = redeem_link_invite(
                body.token,
                own_domain=cfg.server_name,
                trusted_domains=trusted_domains(),
                add_trusted_domain=add_trusted_domain,
                run_federation_sync=run_federation_sync,
                federation_sync_mode="sync",
            )
        except LinkInviteError as exc:
            raise HTTPException(status_code=exc.status, detail=exc.detail) from exc
        status = 200 if not result.already_linked else 409
        return _no_store(
            {
                "linked_domain": result.linked_domain,
                "synapse_federation": result.synapse_federation,
                "mobilizon_relay": result.mobilizon_relay,
                "already_linked": result.already_linked,
            },
            status=status,
        )

    @router.post("/api/link-invites/decline")
    async def api_link_invites_decline(body: LinkInviteTokenBody, request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        try:
            from tinywebstack_dashboard.link_invite import decode_inviter_domain

            inviter = decode_inviter_domain(body.token)
            decline_remote_invite(body.token, inviter)
        except LinkInviteError:
            pass
        return _no_store({"declined": True})

    @router.get("/api/linked-families")
    async def api_linked_families(request: Request):
        require_parent_user(api_user(request, cfg), cfg)
        families = linked_families_payload(trusted_domains(), cfg.server_name)
        return _no_store({"linked_families": families})

    return router
