#!/usr/bin/env bash
set -euo pipefail
cat /etc/matrix-synapse/conf.d/tinywebstack-push.yaml 2>/dev/null || cat /etc/matrix-synapse/conf.d/*.yaml 2>/dev/null | head -20 || true
curl -fsS -m 2 -X POST "http://127.0.0.1:8090/_matrix/push/v1/notify" \
  -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[{"pushkey":"tw-debug","app_id":"test","data":{"url":"http://127.0.0.1:8090/_matrix/push/v1/notify","format":"event_id_only"}}],"content":{"event_id":"$x","room_id":"!r:hs"}}}' \
  && echo "matrix notify ok"
