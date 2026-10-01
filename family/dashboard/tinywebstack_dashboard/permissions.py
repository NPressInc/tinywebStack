"""F1.3 permissions API router (SQLite-backed, shared with the spam checker).

Mounted by app.py via ``create_permissions_router(cfg)``. Reads/writes the
same DB file the Synapse module reads (tinywebstack_permissions), so a parent
edit here flips enforcement immediately.

Auth model (same SSO header + group checks as the rest of the dashboard):
- GET  /permissions/{user}  — any SSO user; non-parents see only themselves.
- PUT  /permissions/{user}  — parents group only (server-side, 403 otherwise);
  parent-only fields: unknown keys and role escalation to an admin role from
  a non-parent are rejected; role may only be an existing seeded role.
If the DB file does not exist yet, PUT seeds it from the bundled role YAMLs
first (mirrors the VM seed step, keeps the lab self-healing).
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    list_group_members,
    username_from_headers,
)

log = logging.getLogger(__name__)

# Fields a kid (or any non-parent) may never modify, even on their own record.
PARENT_ONLY_FIELDS = ("mobilizon_role",)

_MUTABLE_FIELDS = (
    "can_create_rooms",
    "can_create_group_rooms",
    "can_send_3pid_invites",
    "can_publish_rooms",
    "events_enabled",
    "mobilizon_role",
    "allowlist_mxids",
    "allowlist_domains",
    "quiet_hours",
)


def _target_username(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("@") and ":" in raw:
        return raw[1:].split(":", 1)[0]
    return raw.split("@")[0].split(":")[0].strip()


class PermissionsUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: Optional[str] = None
    can_create_rooms: Optional[bool] = None
    can_create_group_rooms: Optional[bool] = None
    can_send_3pid_invites: Optional[bool] = None
    can_publish_rooms: Optional[bool] = None
    events_enabled: Optional[bool] = None
    mobilizon_role: Optional[str] = None
    allowlist_mxids: Optional[list[str]] = Field(default=None)
    allowlist_domains: Optional[list[str]] = Field(default=None)
    quiet_hours: Optional[Dict[str, Any]] = None
    revoke: Optional[list[str]] = Field(default=None)


def _db_path_or_create(server_name: str):
    """Resolve the permissions DB; auto-seed from role YAMLs when missing."""
    from tinywebstack_permissions.store import (
        PermissionsDB,
        default_role_seed_files,
        get_db_path,
    )

    path = get_db_path()
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        role_files = [p for p in default_role_seed_files() if p.is_file()]
        with PermissionsDB(path) as db:
            if role_files:
                db.seed_roles(role_files)
            else:
                db.seed_default_roles()
            if server_name:
                db.set_server_name(server_name)
        log.info("Seeded permissions DB at %s from role definitions", path)
    return path


def _permissions_response(pdb, user: str) -> Dict[str, Any]:
    ps = pdb.get_permissions(user)
    if ps is None:
        raise HTTPException(status_code=404, detail=f"Unknown user: {user}")
    return ps.to_dict()


def _db():
    from tinywebstack_permissions.store import PermissionsDB, get_db_path

    path = get_db_path()
    if not path.is_file():
        return None
    return PermissionsDB(path)


def create_permissions_router(cfg: DashboardConfig) -> APIRouter:
    router = APIRouter(tags=["permissions"])

    def _server_name() -> str:
        server = cfg.server_name or os.environ.get("TWS_SERVER_NAME", "")
        if not server:
            raise HTTPException(status_code=500, detail="TWS_SERVER_NAME not configured")
        return server

    def _mxid_for(username: str) -> str:
        username = username.split("@")[0].strip()
        if not username:
            raise HTTPException(status_code=404, detail="Unknown user")
        if ":" in username:
            return username if username.startswith("@") else f"@{username}"
        return f"@{username}:{_server_name()}"

    def _is_parent(username: str) -> bool:
        return username in list_group_members(cfg.parents_group, cfg.yunohost_cli)

    def sso_user(request: Request) -> str:
        user = username_from_headers(dict(request.headers))
        if not user:
            raise HTTPException(status_code=401, detail="SSO login required")
        return user

    @router.get("/permissions/{user}")
    async def get_permissions(user: str, request: Request):
        caller = sso_user(request)
        target = _target_username(user)
        if not target:
            raise HTTPException(status_code=404, detail="Unknown user")
        if not _is_parent(caller) and target != caller:
            raise HTTPException(status_code=403, detail="You may only view your own permissions")
        # Ensure the caller's household members exist in the store so lookups
        # match the group model even before the seed step has registered them.
        server = _server_name()
        _db_path_or_create(server)
        pdb = _db()
        if pdb is None:  # pragma: no cover — _db_path_or_create just created it
            raise HTTPException(status_code=503, detail="Permissions store unavailable")
        with pdb:
            if pdb.get_permissions(target) is None:
                known_parents = set(
                    list_group_members(cfg.parents_group, cfg.yunohost_cli)
                )
                known_kids = set(list_group_members(cfg.kids_group, cfg.yunohost_cli))
                if target in known_parents:
                    pdb.set_role(_mxid_for(target), "parent", username=target, server_name=server)
                elif target in known_kids:
                    pdb.set_role(_mxid_for(target), "kid", username=target, server_name=server)
            return _permissions_response(pdb, target)

    @router.put("/permissions/{user}")
    async def put_permissions(
        user: str, body: PermissionsUpdate, request: Request
    ):
        caller = sso_user(request)
        # Tamper guard: only members of the parents group may modify anyone's
        # permissions — including a kid editing themselves.
        if not _is_parent(caller):
            raise HTTPException(status_code=403, detail="Parents group membership required")
        target = _target_username(user)
        if not target:
            raise HTTPException(status_code=404, detail="Unknown user")
        server = _server_name()
        _db_path_or_create(server)
        fields = body.model_dump(exclude_unset=True)
        revokes = fields.pop("revoke", None) or []
        target_role = fields.pop("role", None)
        pdb = _db()
        if pdb is None:  # pragma: no cover
            raise HTTPException(status_code=503, detail="Permissions store unavailable")
        with pdb:
            # Caller's LDAP parents-group membership is authoritative; make sure
            # they have a row so the admin-escalation check can consult it.
            if pdb.get_permissions(caller) is None and _is_parent(caller):
                pdb.set_role(_mxid_for(caller), "parent", username=caller, server_name=server)
            known = pdb.get_permissions(target) is not None
            if not known:
                parents = set(list_group_members(cfg.parents_group, cfg.yunohost_cli))
                kids = set(list_group_members(cfg.kids_group, cfg.yunohost_cli))
                if target in parents:
                    pdb.set_role(_mxid_for(target), "parent", username=target, server_name=server)
                    known = True
                elif target in kids:
                    pdb.set_role(_mxid_for(target), "kid", username=target, server_name=server)
                    known = True
            if not known:
                raise HTTPException(status_code=404, detail=f"Unknown user: {target}")
            mxid = _mxid_for(target)
            if target_role is not None:
                role = str(target_role).strip().lower()
                # Parent-only escalation guard: only an admin role (parent) may
                # grant an is_admin role; normal parents can assign kid roles.
                if pdb.role_is_admin(role) and not _is_parent_admin_store(pdb, caller):
                    raise HTTPException(
                        status_code=403,
                        detail="Only an admin may grant administrator roles",
                    )
                try:
                    pdb.set_role(mxid, role, username=target, server_name=server)
                    ps = pdb.get_permissions(target)
                    if ps is not None:
                        mxid = ps.mxid
                except ValueError as exc:
                    raise HTTPException(status_code=400, detail=str(exc)) from exc
            for key in revokes:
                if key not in _MUTABLE_FIELDS:
                    raise HTTPException(status_code=400, detail=f"Cannot revoke: {key}")
                pdb.revoke_permission(mxid, key)
            for key, value in fields.items():
                if value is None or key not in _MUTABLE_FIELDS:
                    continue
                if key in PARENT_ONLY_FIELDS and target == caller:
                    # Parents editing themselves may not lift their own gates.
                    raise HTTPException(
                        status_code=400, detail=f"Field not editable on self: {key}"
                    )
                try:
                    pdb.set_permission(mxid, key, value)
                except KeyError as exc:
                    raise HTTPException(status_code=404, detail=str(exc)) from exc
                except ValueError as exc:
                    raise HTTPException(status_code=400, detail=str(exc)) from exc
            return _permissions_response(pdb, target)

    def _is_parent_admin_store(pdb, caller: str) -> bool:
        ps = pdb.get_permissions(caller)
        return bool(ps and ps.is_admin)

    return router
