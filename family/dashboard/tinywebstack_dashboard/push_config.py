"""Push gateway URLs exposed to enrolled apps (no secrets)."""

from __future__ import annotations

import os
from typing import Any, Dict, Optional


def _push_host(server_name: str) -> str:
    explicit = os.environ.get("TWS_PUSH_PUBLIC_HOST", "").strip()
    if explicit:
        return explicit
    return f"push.{server_name}"


def _local_ntfy_port() -> int:
    return int(os.environ.get("TWS_NTFY_PORT", "8090"))


def _local_sygnal_port() -> int:
    return int(os.environ.get("TWS_SYGNAL_PORT", "5000"))


def push_enabled() -> bool:
    return os.environ.get("TWS_PUSH_ENABLE", "1").strip() not in ("0", "false", "no", "off")


def ios_app_id() -> str:
    bundle = os.environ.get("TWS_APNS_BUNDLE_ID", "win.tinyweb.tinyweb").strip()
    return f"{bundle}.ios"


def android_app_id() -> str:
    bundle = os.environ.get("TWS_ANDROID_APP_ID", "win.tinyweb.tinyweb.android").strip()
    return bundle


def enroll_push_section(server_name: str) -> Optional[Dict[str, Any]]:
    if not push_enabled():
        return None
    host = _push_host(server_name)
    ntfy_port = _local_ntfy_port()
    sygnal_port = _local_sygnal_port()
    unified_local = f"http://127.0.0.1:{ntfy_port}/_matrix/push/v1/notify"
    sygnal_local = f"http://127.0.0.1:{sygnal_port}/_matrix/push/v1/notify"
    public_base = f"https://{host}"
    return {
        "unifiedpush": {
            "gateway_url": unified_local,
            "public_base": public_base,
        },
        "sygnal": {
            "gateway_url": sygnal_local,
            "public_base": public_base,
            "ios_app_id": ios_app_id(),
            "android_app_id": android_app_id(),
        },
    }
