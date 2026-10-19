#!/usr/bin/env bash
grep -ri push /etc/matrix-synapse/homeserver.yaml /etc/matrix-synapse/conf.d/ 2>/dev/null | head -30 || true
journalctl -u synapse -n 30 --no-pager 2>/dev/null | grep -i push || true
