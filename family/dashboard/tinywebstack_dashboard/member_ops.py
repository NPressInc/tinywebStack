"""Shared family member admin actions (HTML forms and parent JSON API)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Literal, Optional

from fastapi import HTTPException

from tinywebstack_dashboard.auth import DashboardConfig, list_group_members, user_in_group
from tinywebstack_dashboard.app_devices import create_enroll_code, get_device, list_devices_for_user, revoke_device
from tinywebstack_dashboard.invite_store import add_pending, load_pending, pop_pending
from tinywebstack_dashboard.yunohost_actions import (
    create_member,
    delete_member,
    generate_password,
    reset_password,
    validate_username,
)
from tinywebstack_family.invite import create_invite_token

Role = Literal["parent", "kid"]


def member_role(cfg: DashboardConfig, username: str) -> str | None:
    if user_in_group(username, cfg.parents_group, cfg.yunohost_cli):
        return "parent"
    if user_in_group(username, cfg.kids_group, cfg.yunohost_cli):
        return "kid"
    return None


def assert_removable_member(cfg: DashboardConfig, actor: str, username: str) -> None:
    if username == actor:
        raise HTTPException(status_code=400, detail="You cannot remove your own account here")
    if not member_role(cfg, username):
        raise HTTPException(status_code=404, detail="Not a family member")
    if member_role(cfg, username) == "parent":
        parents = list_group_members(cfg.parents_group, cfg.yunohost_cli)
        if len(parents) <= 1:
            raise HTTPException(status_code=400, detail="Cannot remove the last parent account")


@dataclass
class CreateMemberResult:
    username: str
    role: Role
    password: str
    enroll_code: Optional[str] = None
    enroll_expires_at: Optional[str] = None
    enroll_qr_payload: Optional[str] = None


def create_family_member(
    cfg: DashboardConfig,
    *,
    username: str,
    role: str,
    display_name: Optional[str],
    issue_enroll_code: bool,
    enroll_issued_by: str,
) -> CreateMemberResult:
    try:
        uname = validate_username(username)
        if role not in ("parent", "kid"):
            raise ValueError("Role must be parent or kid")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    name = (display_name or uname).strip()
    if not name:
        raise HTTPException(status_code=400, detail="display_name required")
    password = generate_password()
    create_member(uname, name, role, cfg.server_name, password)
    out = CreateMemberResult(username=uname, role=role, password=password)
    if issue_enroll_code:
        code, expires_at = create_enroll_code(uname, enroll_issued_by)
        out.enroll_code = code
        out.enroll_expires_at = expires_at
        out.enroll_qr_payload = f"tinyweb://enroll?server={cfg.server_name}&code={code}"
    return out


def reset_member_password(cfg: DashboardConfig, username: str) -> str:
    if not member_role(cfg, username):
        raise HTTPException(status_code=404, detail="Not a family member")
    password = generate_password()
    reset_password(username, password)
    revoke_user_devices(username, cfg.server_name)
    return password


def revoke_user_devices(username: str, server_name: str) -> None:
    """Revoke all app devices for a user (e.g. password reset). Best-effort cleanup."""
    from tinywebstack_dashboard.app_devices import revoke_all_for_user
    from tinywebstack_dashboard.yunohost_actions import (
        matrix_device_delete,
        nextcloud_app_password_delete,
    )

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


def remove_family_member(cfg: DashboardConfig, actor: str, username: str) -> Dict[str, str]:
    assert_removable_member(cfg, actor, username)
    return delete_member(username)


def issue_member_enroll_code(
    cfg: DashboardConfig, username: str, parent_user: str
) -> Dict[str, str]:
    if not member_role(cfg, username):
        raise HTTPException(status_code=404, detail="Not a family member")
    code, expires_at = create_enroll_code(username, parent_user)
    qr_payload = f"tinyweb://enroll?server={cfg.server_name}&code={code}"
    return {"code": code, "expires_at": expires_at, "qr_payload": qr_payload}


def list_member_devices_public(username: str) -> list:
    return [d.to_public_dict() for d in list_devices_for_user(username)]


def revoke_member_app_device(cfg: DashboardConfig, username: str, device_id: str) -> None:
    from tinywebstack_dashboard.yunohost_actions import (
        matrix_device_delete,
        nextcloud_app_password_delete,
    )

    if not member_role(cfg, username):
        raise HTTPException(status_code=404, detail="Not a family member")
    dev = get_device(device_id)
    if not dev or dev.username != username:
        raise HTTPException(status_code=404, detail="Device not found")
    revoke_device(device_id)
    if dev.matrix_device_id:
        try:
            matrix_device_delete(username, cfg.server_name, dev.matrix_device_id)
        except Exception:
            pass
    if dev.nextcloud_token_id:
        try:
            nextcloud_app_password_delete(username, dev.nextcloud_token_id)
        except Exception:
            pass


def create_pending_family_invite(
    *,
    server_name: str,
    invite_secret: str,
    pending_path: Path,
    created_by: str,
    public_base_url: str,
) -> Dict[str, str]:
    token, nonce = create_invite_token(server_name, invite_secret)
    add_pending(
        pending_path,
        nonce,
        {"created_by": created_by, "issuer": server_name},
    )
    base = public_base_url.rstrip("/")
    invite_url = f"{base}/invite/redeem?token={token}"
    return {"token": token, "nonce": nonce, "invite_url": invite_url}


def delete_pending_family_invite(pending_path: Path, nonce: str) -> None:
    pending = load_pending(pending_path)
    entry = (pending.get("invites") or {}).get(nonce)
    if not entry or entry.get("used"):
        raise HTTPException(status_code=404, detail="Invite not found")
    if pop_pending(pending_path, nonce) is None:
        raise HTTPException(status_code=404, detail="Invite not found")
