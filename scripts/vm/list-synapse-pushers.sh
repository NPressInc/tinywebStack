#!/usr/bin/env bash
set -euo pipefail
DB=""
for p in /var/lib/matrix-synapse/homeserver.db /var/lib/matrix-synapse/homeserver.db \
  /var/lib/postgresql/*/main/matrix*; do
  [[ -f "$p" ]] && DB="$p" && break
done
if [[ -z "$DB" ]]; then
  DB="$(find /var/lib/matrix-synapse -name '*.db' 2>/dev/null | head -1)"
fi
echo "db=$DB"
if [[ -n "$DB" && -f "$DB" ]]; then
  sqlite3 "$DB" "SELECT user_name, app_id, pushkey, data FROM pushers LIMIT 10;" 2>/dev/null || true
fi
