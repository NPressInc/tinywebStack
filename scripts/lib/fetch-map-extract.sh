#!/usr/bin/env bash
# Extract a regional Protomaps PMTiles basemap for self-hosted family maps.
# One-time download from build.protomaps.com at install time (see docs/MAP.md).
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${_LIB_DIR}/common.sh"

PMTILES_VERSION="${TWS_PMTILES_CLI_VERSION:-1.31.2}"

MAP_DATA_DIR="${TWS_MAP_DATA_DIR:-/var/lib/tinywebstack/map}"
MAP_MAXZOOM="${TWS_MAP_MAXZOOM:-14}"
MAP_SOURCE_URL="${TWS_MAP_SOURCE_URL:-}"
DRY_RUN=0

MAP_DASH_USER="${TWS_MAP_DASHBOARD_USER:-www-data}"
MAP_DASH_GROUP="${TWS_MAP_DASHBOARD_GROUP:-www-data}"

# Named presets: minlon,minlat,maxlon,maxlat
declare -A MAP_REGION_PRESETS=(
  ["colorado-front-range"]="-109.2,39.5,-104.5,41.2"
  ["us-colorado"]="-109.1,36.9,-102.0,41.1"
)

usage() {
  cat <<'EOF'
Usage: fetch-map-extract.sh [--dry-run]

Environment:
  TWS_MAP_BBOX          minlon,minlat,maxlon,maxlat (required unless TWS_MAP_REGION preset)
  TWS_MAP_REGION        preset name (see MAP.md)
  TWS_MAP_MAXZOOM       default 14
  TWS_MAP_SOURCE_URL    override Protomaps build URL
  TWS_MAP_BUILD_DATE    YYYYMMDD build on build.protomaps.com (optional)
  TWS_MAP_DATA_DIR      output directory (default /var/lib/tinywebstack/map)
  TWS_PMTILES_BIN       use this pmtiles CLI instead of downloading one

  --dry-run             print planned commands; do not download or write files.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

load_config 2>/dev/null || true
if [[ -f "${TW_STACK_ROOT}/config/tinyweb.env" ]]; then
  # shellcheck source=/dev/null
  source "${TW_STACK_ROOT}/config/tinyweb.env"
elif [[ -f /etc/tinywebstack/tinyweb.env ]]; then
  # shellcheck source=/dev/null
  source /etc/tinywebstack/tinyweb.env
fi

MAP_MAXZOOM="${TWS_MAP_MAXZOOM:-$MAP_MAXZOOM}"
MAP_DATA_DIR="${TWS_MAP_DATA_DIR:-$MAP_DATA_DIR}"

bbox="${TWS_MAP_BBOX:-}"
if [[ -z "$bbox" && -n "${TWS_MAP_REGION:-}" ]]; then
  preset="${TWS_MAP_REGION}"
  if [[ -z "${MAP_REGION_PRESETS[$preset]:-}" ]]; then
    die "Unknown TWS_MAP_REGION preset: ${preset}"
  fi
  bbox="${MAP_REGION_PRESETS[$preset]}"
fi

if [[ -z "$bbox" ]]; then
  log "Skipping map extract: set TWS_MAP_BBOX or TWS_MAP_REGION (see docs/MAP.md)."
  exit 0
fi

probe_newest_protomaps_build() {
  local i d url
  for i in $(seq 0 9); do
    d="$(date -u -d "today - ${i} days" +%Y%m%d)"
    url="https://build.protomaps.com/${d}.pmtiles"
    if curl -sfI -o /dev/null "$url"; then
      log "Protomaps build probe: ${url} (HTTP 200)"
      echo "$url"
      return 0
    fi
  done
  die "No Protomaps daily build responded with HTTP 200 in the last 10 UTC days (tried build.protomaps.com/YYYYMMDD.pmtiles)."
}

resolve_map_source_url() {
  if [[ -n "$MAP_SOURCE_URL" ]]; then
    return 0
  fi
  if [[ -n "${TWS_MAP_BUILD_DATE:-}" ]]; then
    MAP_SOURCE_URL="https://build.protomaps.com/${TWS_MAP_BUILD_DATE}.pmtiles"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would probe https://build.protomaps.com/<YYYYMMDD>.pmtiles (HEAD) for the newest of the last 10 UTC days"
    MAP_SOURCE_URL="https://build.protomaps.com/<YYYYMMDD>.pmtiles"
    return 0
  fi
  MAP_SOURCE_URL="$(probe_newest_protomaps_build)"
}

install_pmtiles_cli() {
  if [[ -n "${TWS_PMTILES_BIN:-}" && -x "${TWS_PMTILES_BIN}" ]]; then
    echo "${TWS_PMTILES_BIN}"
    return 0
  fi
  local tools_dir="${TW_STACK_ROOT}/.tools/pmtiles"
  local bin="${tools_dir}/pmtiles"
  if [[ -x "$bin" ]]; then
    echo "$bin"
    return 0
  fi
  mkdir -p "$tools_dir"
  local arch url expected
  arch="$(uname -m)"
  case "$arch" in
    x86_64)
      url="https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz"
      expected="${TWS_PMTILES_SHA256_x86_64:-3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f}"
      ;;
    aarch64|arm64)
      url="https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_arm64.tar.gz"
      expected="${TWS_PMTILES_SHA256_aarch64:-f8bd47e7ea866863489cad588fbaf2f31f42e5821f7a03f009b3769f05801cb1}"
      ;;
    *)
      die "Unsupported architecture for pmtiles CLI: ${arch}"
      ;;
  esac
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would download pmtiles CLI from ${url} and verify tarball sha256"
    echo "${tools_dir}/pmtiles"
    return 0
  fi
  local tgz
  tgz="$(mktemp)"
  curl -fsSL "$url" -o "$tgz"
  if ! echo "$expected  $tgz" | sha256sum --quiet -c - >&2; then
    rm -f "$tgz"
    die "pmtiles CLI tarball checksum mismatch (expected ${expected})"
  fi
  tar -xzf "$tgz" -C "$tools_dir" pmtiles
  rm -f "$tgz"
  chmod +x "${tools_dir}/pmtiles"
  echo "$bin"
}

map_assets_src() {
  local assets_src="${TW_STACK_ROOT}/family/map_assets"
  if [[ ! -d "$assets_src" && -d "${TW_STACK_ROOT}/../family/map_assets" ]]; then
    assets_src="${TW_STACK_ROOT}/../family/map_assets"
  fi
  if [[ -d "$assets_src" ]]; then
    echo "$assets_src"
  fi
}

set_map_data_permissions() {
  local dir=$1
  chmod 755 "$dir"
  find "$dir" -type d -exec chmod 755 {} +
  find "$dir" -type f -exec chmod 644 {} +
  if [[ "$(id -u)" == "0" ]] && id "$MAP_DASH_USER" &>/dev/null; then
    chown -R "${MAP_DASH_USER}:${MAP_DASH_GROUP}" "$dir"
  fi
}

install_map_assets() {
  local out_dir=$1
  local assets_src
  assets_src="$(map_assets_src || true)"
  if [[ -z "$assets_src" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would rsync map style assets from ${assets_src}/ to ${out_dir}/ (no --delete)"
    return 0
  fi
  rsync -a "${assets_src}/" "${out_dir}/"
  set_map_data_permissions "$out_dir"
  log "Installed map style assets from ${assets_src}"
}

resolve_map_source_url
PMTILES_BIN="$(install_pmtiles_cli)"
out_dir="$MAP_DATA_DIR"
out_file="${out_dir}/basemap.pmtiles"
tmp_file="${out_dir}/.basemap.pmtiles.tmp"
meta_file="${out_dir}/map.meta.json"
meta_tmp="${out_dir}/.map.meta.json.tmp"

log "Map extract bbox=${bbox} maxzoom=${MAP_MAXZOOM} source=${MAP_SOURCE_URL}"

if [[ "$DRY_RUN" == "1" ]]; then
  log "[dry-run] ${PMTILES_BIN} extract ${MAP_SOURCE_URL} ${tmp_file} --bbox=${bbox} --maxzoom=${MAP_MAXZOOM}"
  log "[dry-run] atomic replace -> ${out_file} and write ${meta_file}"
  install_map_assets "$out_dir"
  exit 0
fi

require_cmd curl
mkdir -p "$out_dir"
chmod 755 "$out_dir"

cleanup_extract_failure() {
  rm -f "$tmp_file" "$meta_tmp"
}

trap cleanup_extract_failure ERR

"${PMTILES_BIN}" extract "$MAP_SOURCE_URL" "$tmp_file" --bbox="$bbox" --maxzoom="$MAP_MAXZOOM"

IFS=',' read -r minlon minlat maxlon maxlat <<<"$bbox"
flavor="${TWS_MAP_FLAVOR:-light}"
cat >"$meta_tmp" <<EOF
{
  "bounds": [${minlon}, ${minlat}, ${maxlon}, ${maxlat}],
  "maxzoom": ${MAP_MAXZOOM},
  "flavor": "${flavor}",
  "sprites_path": "sprites/v4/${flavor}"
}
EOF
mv -f "$tmp_file" "$out_file"
mv -f "$meta_tmp" "$meta_file"
trap - ERR

set_map_data_permissions "$out_dir"
log "Wrote ${out_file} ($(du -h "$out_file" | awk '{print $1}'))"

install_map_assets "$out_dir"
