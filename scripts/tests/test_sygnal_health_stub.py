"""Sygnal stub must not report a successful push when operator keys are missing."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STUB = ROOT / "scripts" / "vm" / "sygnal-health-stub.py"


def _load():
    spec = importlib.util.spec_from_file_location("sygnal_health_stub", STUB)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_notify_refuses_delivery() -> None:
    stub = _load()
    code, body = stub.notify_response()
    assert code == 503
    assert body["delivery"] == "refused"
    assert "rejected" not in body
    assert body != {"rejected": []}


def test_health_stays_up_as_unconfigured_stub() -> None:
    stub = _load()
    code, body = stub.health_response()
    assert code == 200
    assert body["mode"] == "stub"
    assert body["configured"] is False
    assert body["delivery"] == "refused"
