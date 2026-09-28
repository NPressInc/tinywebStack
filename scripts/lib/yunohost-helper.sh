#!/usr/bin/env bash
set -euo pipefail

_yunohost_domains_json() {
  yunohost domain list --output-as json 2>/dev/null || yunohost domain list --output-as plain 2>/dev/null
}

yunohost_domain_exists() {
  local domain=$1
  local json
  json="$(_yunohost_domains_json)" || return 1
  python3 - <<PY "$domain" "$json"
import json, sys
domain, raw = sys.argv[1], sys.argv[2]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
if isinstance(data, list):
    sys.exit(0 if domain in data else 1)
if isinstance(data, dict):
    domains = data.get("domains") or data.get("maindomains") or list(data.keys())
    if isinstance(domains, dict):
        domains = list(domains.keys())
    sys.exit(0 if domain in domains else 1)
sys.exit(1)
PY
}

yunohost_domain_has_cert() {
  local domain=$1
  [[ -f "/etc/yunohost/certs/${domain}/crt.pem" ]] && return 0
  local json
  json="$(yunohost domain cert list --output-as json 2>/dev/null)" || return 1
  python3 - <<PY "$domain" "$json"
import json, sys
domain, raw = sys.argv[1], sys.argv[2]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
certs = data
if isinstance(data, dict):
    certs = data.get("certificates") or data.get("certs") or data
if isinstance(certs, dict):
    sys.exit(0 if domain in certs else 1)
if isinstance(certs, list):
    names = [c if isinstance(c, str) else c.get("domain", "") for c in certs]
    sys.exit(0 if domain in names else 1)
sys.exit(1)
PY
}
