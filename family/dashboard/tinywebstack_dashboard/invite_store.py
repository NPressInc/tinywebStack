"""Pending invite nonces on disk (issuer side)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

from tinywebstack_family.policy import write_policy_atomic


def load_pending(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        return {"invites": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return {"invites": {}}
    data.setdefault("invites", {})
    return data


def save_pending(path: Path, data: Dict[str, Any]) -> None:
    write_policy_atomic(path, data)


def add_pending(path: Path, nonce: str, meta: Dict[str, Any]) -> None:
    data = load_pending(path)
    data["invites"][nonce] = meta
    save_pending(path, data)


def pop_pending(path: Path, nonce: str) -> Dict[str, Any] | None:
    data = load_pending(path)
    entry = data["invites"].pop(nonce, None)
    save_pending(path, data)
    return entry
