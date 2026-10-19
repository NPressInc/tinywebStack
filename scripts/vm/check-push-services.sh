#!/usr/bin/env bash
set -euo pipefail
systemctl is-active tinywebstack-ntfy tinywebstack-sygnal || true
journalctl -u tinywebstack-ntfy -n 15 --no-pager || true
curl -fsS -m 2 "http://127.0.0.1:8090/v1/health" || echo "ntfy health failed"
