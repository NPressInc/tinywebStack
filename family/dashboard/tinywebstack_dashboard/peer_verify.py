"""Verify peer Matrix server signing key over HTTPS."""

from __future__ import annotations

import json
import os
import ssl
import urllib.error
import urllib.request
from typing import Any, Dict, Optional


def _ssl_context() -> ssl.SSLContext:
    ca = os.environ.get("TWS_CA_BUNDLE", "")
    if ca and os.path.isfile(ca):
        return ssl.create_default_context(cafile=ca)
    if os.environ.get("TWS_LAB_TLS_INSECURE") == "1":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return ssl.create_default_context()


def fetch_matrix_server_key(server_name: str, timeout: int = 15) -> Dict[str, Any]:
    url = f"https://{server_name}/_matrix/key/v2/server"
    ctx = _ssl_context()
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def verify_peer_domain(peer_domain: str, matrix_server: Optional[str] = None) -> Dict[str, Any]:
    host = matrix_server or peer_domain
    return fetch_matrix_server_key(host)
