#!/usr/bin/env python3
"""Loopback health + Matrix push noop when Sygnal has no APNs/FCM apps configured."""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: ARG002
        return

    def do_GET(self) -> None:
        if self.path.rstrip("/") in ("/health", ""):
            self._json(200, {"status": "ok", "mode": "stub"})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path.rstrip("/") == "/_matrix/push/v1/notify":
            self._json(200, {"rejected": []})
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
