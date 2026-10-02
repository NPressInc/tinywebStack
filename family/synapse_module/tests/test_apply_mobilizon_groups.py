"""YunoHost group list JSON shape for apply_mobilizon_permissions."""

import importlib.util
import json
from pathlib import Path

import pytest


def _load_apply_module():
    path = Path(__file__).resolve().parents[3] / "scripts" / "lib" / "apply_mobilizon_permissions.py"
    spec = importlib.util.spec_from_file_location("apply_mobilizon_permissions", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_ensure_group_recognizes_wrapped_yunohost_list(monkeypatch):
    mod = _load_apply_module()
    payload = {"groups": {"events-users": {"name": "events-users"}}}
    calls = {"create": 0}

    def fake_run_json(cmd):
        assert "group" in cmd and "list" in cmd
        return payload

    def fake_ynh(*args, check=False):
        if args[:2] == ("group", "create"):
            calls["create"] += 1
        class R:
            returncode = 0
            stderr = ""
        return R()

    monkeypatch.setattr(mod, "_run_json", fake_run_json)
    monkeypatch.setattr(mod, "_ynh", fake_ynh)
    mod._ensure_group("events-users")
    assert calls["create"] == 0
