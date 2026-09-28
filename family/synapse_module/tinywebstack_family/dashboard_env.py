"""Parse dashboard EnvironmentFile safely (values may contain spaces)."""

from __future__ import annotations

import secrets
import string
from pathlib import Path


def parse_env_file(path: str | Path) -> dict[str, str]:
    """Parse KEY=VALUE lines; supports optional double-quoted values."""
    result: dict[str, str] = {}
    text = Path(path).read_text(encoding="utf-8")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] == '"':
            val = val[1:-1].replace('\\"', '"')
        result[key] = val
    return result


def random_synapse_local_password(length: int = 32) -> str:
    """Password stored in Synapse local DB only; Matrix auth uses LDAP (YunoHost)."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def synapse_admin_user_body(*, yunohost_password: str) -> dict[str, object]:
    """Build Synapse admin PUT body; local password must not match the YunoHost password."""
    local = random_synapse_local_password()
    while local == yunohost_password:
        local = random_synapse_local_password()
    return {"password": local, "deactivated": False}
