#!/usr/bin/env bash
set -euo pipefail

yunohost_domain_exists() {
  local domain=$1
  yunohost domain list 2>/dev/null | grep -Fxq "$domain"
}

yunohost_domain_has_cert() {
  local domain=$1
  [[ -f "/etc/yunohost/certs/${domain}/crt.pem" ]] && return 0
  yunohost domain cert list 2>/dev/null | grep -Fxq "$domain"
}
