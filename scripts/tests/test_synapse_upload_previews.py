"""synapse-upload-previews.sh rendered config and install wiring."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "vm" / "synapse-upload-previews.sh"
TEMPLATE = ROOT / "templates" / "synapse" / "tinywebstack-media.yaml.example"
FAMILY_INIT = ROOT / "scripts" / "vm" / "family-init.sh"


def _dry_run_render(domain: str = "family-a.family.test") -> str:
    env = {
        **os.environ,
        "DRY_RUN": "1",
        "TW_STACK_SKIP_LOCAL_ENV": "1",
    }
    return subprocess.check_output(
        ["bash", str(SCRIPT), domain],
        text=True,
        env=env,
        cwd=ROOT,
    )


def test_template_yaml_values() -> None:
    data = yaml.safe_load(TEMPLATE.read_text(encoding="utf-8"))
    assert data["max_upload_size"] == "200M"
    assert data["url_preview_enabled"] is False
    assert "url_preview_ip_range_blacklist" not in data


def test_dry_run_synapse_snippet() -> None:
    out = _dry_run_render()
    synapse_part = out.split("---", 1)[0]
    data = yaml.safe_load(synapse_part)
    assert data["max_upload_size"] == "200M"
    assert data["url_preview_enabled"] is False
    assert "url_preview_ip_range_blacklist" not in data


def test_dry_run_nginx_body_size() -> None:
    out = _dry_run_render()
    assert "client_max_body_size 200M" in out


def test_family_init_invokes_script() -> None:
    text = FAMILY_INIT.read_text(encoding="utf-8")
    assert "synapse-upload-previews.sh" in text
