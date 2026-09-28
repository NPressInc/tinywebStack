"""Invoke narrowly-scoped sudo helpers for YunoHost user management."""

from __future__ import annotations

import os
import re
import secrets
import string
import subprocess
from typing import Literal, Optional

Role = Literal["parent", "kid"]

_USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,30}$")


def validate_username(username: str) -> str:
    u = username.strip().lower()
    if not _USERNAME_RE.match(u):
        raise ValueError("Username must be 2–31 characters: lowercase letters, digits, _ or -")
    return u


def generate_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _helper_cmd() -> list[str]:
    path = os.environ.get(
        "TWS_YUNOHOST_PRIV_HELPER",
        "sudo /usr/local/sbin/tws-family-dashboard-privileged",
    )
    return path.split()


def run_helper(*args: str) -> str:
    if os.environ.get("TWS_DASHBOARD_MOCK_YUNOHOST"):
        if args and args[0] == "synapse-user-status":
            local, server = args[1], args[2]
            return f"status=active mxid=@{local}:{server}"
        if args and args[0] == "owntracks-issue":
            user = args[1]
            return (
                f"OK user={user} device={user}-phone password=mockpass "
                f"url=https://loc.test/api/ tid={user[:2]}"
            )
        return f"OK mock {' '.join(args)}"
    out = subprocess.check_output([*_helper_cmd(), *args], text=True, stderr=subprocess.STDOUT)
    return out.strip()


def create_member(username: str, full_name: str, role: Role, domain: str, password: str) -> None:
    run_helper("user-create", username, full_name, role, domain, password)


def delete_member(username: str) -> None:
    run_helper("user-delete", username)


def reset_password(username: str, password: str) -> None:
    run_helper("password-reset", username, password)


def synapse_user_status(localpart: str, server_name: str) -> dict[str, str]:
    line = run_helper("synapse-user-status", localpart, server_name)
    parts: dict[str, str] = {}
    for token in line.split():
        if "=" in token:
            k, v = token.split("=", 1)
            parts[k] = v
    return parts


def issue_owntracks(user: str, main_domain: str, location_domain: str) -> dict[str, str]:
    line = run_helper("owntracks-issue", user, main_domain, location_domain)
    parts: dict[str, str] = {}
    for token in line.split():
        if "=" in token:
            k, v = token.split("=", 1)
            parts[k] = v
    return parts
