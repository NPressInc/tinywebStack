#!/usr/bin/env bash
# Portal permission tiles (YunoHost 12: --show_tile must be True/False, not true/false).

ynh_permission_update() {
  local perm=$1
  shift
  local out
  if out="$(yunohost user permission update "$perm" "$@" 2>&1)"; then
    return 0
  fi
  log "WARN: yunohost user permission update ${perm} $*: ${out}"
  return 1
}

install_tinyweb_family_tile_png() {
  local dst=${1:-/usr/share/yunohost/portal/customassets/tinyweb-family-tile.png}
  install -d /usr/share/yunohost/portal/customassets
  local src="${TW_STACK_ROOT}/brand/portal/tinyweb-family-tile.png"
  local svg="${TW_STACK_ROOT}/brand/portal/tinyweb-logo.svg"
  if [[ -f "$src" ]]; then
    install -m 644 "$src" "$dst"
    return 0
  fi
  if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "$svg" ]]; then
    rsvg-convert -w 256 -h 256 "$svg" -o "$dst"
    chmod 644 "$dst"
    return 0
  fi
  log "WARN: missing ${src} (and no rsvg-convert); Family home tile logo not installed"
  return 1
}

configure_family_home_tile() {
  local perm=$1
  local logo=${2:-/usr/share/yunohost/portal/customassets/tinyweb-family-tile.png}
  install_tinyweb_family_tile_png "$logo" || true
  if [[ -f "$logo" ]]; then
    ynh_permission_update "$perm" --show_tile True --label "Family home" --logo "$logo"
  else
    ynh_permission_update "$perm" --show_tile True --label "Family home"
  fi
}

configure_element_tile_logo() {
  local perm=element.main
  local logo=""
  for candidate in \
    /usr/share/yunohost/apps/element/logo.png \
    /usr/share/yunohost/apps/element/logo-128.png \
    /etc/yunohost/apps/element/conf/logo.png \
    "${TW_STACK_ROOT}/brand/portal/element-tile.png"; do
    if [[ -f "$candidate" ]]; then
      logo=$candidate
      break
    fi
  done
  [[ -n "$logo" ]] || {
    log "WARN: no Element tile logo found on this node (portal icon may 404)"
    return 1
  }
  ynh_permission_update "$perm" --logo "$logo"
}

hide_portal_tile() {
  local perm=$1
  ynh_permission_update "$perm" --show_tile False || true
}
