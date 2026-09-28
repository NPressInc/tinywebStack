#!/usr/bin/env bash
# Restrict Matrix federation to an explicit domain allowlist.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: synapse-federation-allowlist.sh LOCAL_DOMAIN ALLOWED_DOMAIN [ALLOWED_DOMAIN...]

Updates federation_domain_whitelist in /etc/matrix-synapse/homeserver.yaml (marked block,
preserved across re-runs) and restarts Synapse.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage

LOCAL_DOMAIN=$1
shift
ALLOWED=("$@")

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the YunoHost VM" >&2
  exit 1
fi

HOMESERVER="/etc/matrix-synapse/homeserver.yaml"
MARK_BEGIN="# tinywebstack-federation-begin"
MARK_END="# tinywebstack-federation-end"

[[ -f "$HOMESERVER" ]] || { echo "Synapse not installed? Missing ${HOMESERVER}" >&2; exit 1; }

BLOCK_FILE="$(mktemp)"
{
  echo "$MARK_BEGIN"
  echo "federation_domain_whitelist:"
  for d in "${ALLOWED[@]}"; do
    printf '  - "%s"\n' "$d"
  done
  echo "$MARK_END"
} > "$BLOCK_FILE"

TMP="$(mktemp)"
awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
  $0 == begin { skip=1; next }
  $0 == end { skip=0; next }
  !skip { print }
' "$HOMESERVER" > "$TMP"
cat "$BLOCK_FILE" >> "$TMP"

if cmp -s "$TMP" "$HOMESERVER"; then
  rm -f "$TMP" "$BLOCK_FILE"
  echo "Federation allowlist unchanged on ${LOCAL_DOMAIN}"
  exit 0
fi

cp "$TMP" "$HOMESERVER"
rm -f "$TMP" "$BLOCK_FILE"

systemctl restart matrix-synapse
echo "Federation allowlist updated on ${LOCAL_DOMAIN}: ${ALLOWED[*]}"
