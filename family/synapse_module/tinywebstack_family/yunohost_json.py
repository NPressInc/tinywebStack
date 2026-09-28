"""Parse YunoHost 12 CLI JSON shapes (groups, permissions, users)."""

from __future__ import annotations

from typing import Any, Mapping


def groups_map(payload: Any) -> Mapping[str, Any]:
    if isinstance(payload, dict) and "groups" in payload:
        inner = payload["groups"]
        if isinstance(inner, dict):
            return inner
    if isinstance(payload, dict):
        return payload
    return {}


def permissions_map(payload: Any) -> Mapping[str, Any]:
    if isinstance(payload, dict) and "permissions" in payload:
        inner = payload["permissions"]
        if isinstance(inner, dict):
            return inner
    if isinstance(payload, dict):
        return payload
    return {}


def users_map(payload: Any) -> Mapping[str, Any]:
    if isinstance(payload, dict) and "users" in payload:
        inner = payload["users"]
        if isinstance(inner, dict):
            return inner
    if isinstance(payload, dict):
        return payload
    return {}


def group_exists(payload: Any, name: str) -> bool:
    return name in groups_map(payload)


def permission_exists(payload: Any, name: str) -> bool:
    return name in permissions_map(payload)
