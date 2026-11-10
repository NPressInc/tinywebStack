"""Shared fixtures. No Cloudflare credentials are required."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tinyweb_controlplane.app import create_app  # noqa: E402
from tinyweb_controlplane.config import Settings  # noqa: E402
from tinyweb_controlplane.providers import FakeProvider  # noqa: E402


@pytest.fixture
def world(tmp_path: Path):
    settings = Settings(
        db_path=str(tmp_path / "cp.sqlite"),
        operator_token="operator-test-token",
        ddns_token="ddns-test-token",
        provider_name="fake",
        base_domain="tinyweb.win",
        public_origin="https://tinyweb.win",
    )
    provider = FakeProvider()
    app = create_app(settings, provider=provider)
    with TestClient(app) as client:
        yield SimpleNamespace(client=client, provider=provider, settings=settings, app=app, db=tmp_path / "cp.sqlite")
