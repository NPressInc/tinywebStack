#!/usr/bin/env python3
"""Loopback health when TinyWeb APNs/FCM credentials are not configured.

GET /health stays up so the unit can be supervised. POST notify refuses
delivery. It does not answer 200 with an empty rejected list.
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

HEALTH_STATUS = 200
HEALTH_BODY = {
    "status": "ok",
    "mode": "stub",
    "configured": False,
    "delivery": "refused",
}
NOTIFY_STATUS = 503
NOTIFY_BODY = {
    "error": "TinyWeb push operator credentials are not configured",
    "delivery": "refused",
}


def health_response() -> tuple[int, dict]:
    return HEALTH_STATUS, dict(HEALTH_BODY)


def notify_response() -> tuple[int, dict]:
    return NOTIFY_STATUS, dict(NOTIFY_BODY)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: ARG002
        return

    def do_GET(self) -> None:
        if self.path.rstrip("/") in ("/health", ""):
            code, body = health_response()
            self._json(code, body)
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path.rstrip("/") == "/_matrix/push/v1/notify":
            code, body = notify_response()
            self._json(code, body)
            return
        self._json(404, {"error": "not found"})

    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    port = int(os.environ.get("TWS_SYGNAL_PORT", "5000"))
    bind = os.environ.get("TWS_SYGNAL_BIND", "127.0.0.1")
    HTTPServer((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
