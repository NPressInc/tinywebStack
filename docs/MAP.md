# Self-hosted family map (Protomaps PMTiles)

Parents see kid locations on a **vector map** rendered in the TinyWeb app. Tiles, fonts, and sprites are served from the family box — the app does not contact third-party map CDNs at runtime.

## One-time external download

The regional basemap is extracted at install time from [Protomaps build](https://build.protomaps.com/) (`YYYYMMDD.pmtiles`). That is the **only** intended external fetch for map data. Fonts/sprites in git come from [protomaps/basemaps-assets](https://github.com/protomaps/basemaps-assets) (CC0).

If `TWS_MAP_SOURCE_URL` and `TWS_MAP_BUILD_DATE` are unset, `fetch-map-extract.sh` probes the newest daily build by issuing `HEAD` requests for today’s UTC date and up to nine prior days, then uses the first URL that returns HTTP 200. Set `TWS_MAP_BUILD_DATE=YYYYMMDD` to pin a specific build, or `TWS_MAP_SOURCE_URL` for a full override.

## Choosing a region

1. Pick a bounding box with [bboxfinder.com](http://bboxfinder.com/) (or similar): `minlon,minlat,maxlon,maxlat`.
2. Set in `/etc/tinywebstack/tinyweb.env` (or export before install):

   - `TWS_MAP_BBOX=-105.1,39.7,-104.9,39.8` — explicit box
   - `TWS_MAP_REGION=colorado-front-range` — named preset (see `scripts/lib/fetch-map-extract.sh`)
   - `TWS_MAP_MAXZOOM=14` (default) — higher zoom increases size quickly

3. Run on the box:

   ```bash
   sudo bash /opt/tinywebstack/lib/fetch-map-extract.sh
   ```

   Or set variables before `install-tinyweb.sh` / `family-init.sh` (optional step runs the same script).

If neither `TWS_MAP_BBOX` nor `TWS_MAP_REGION` is set, the script exits successfully with a skip message and the app shows the **list** view only.

### Approximate sizes (z14 vector extract)

| Area | Rough size |
|------|------------|
| City / metro | tens of MB |
| US state | ~1–few GB |
| Planet | ~120 GB — **not supported** |

Refresh the map by re-running `fetch-map-extract.sh` (atomic replace of `basemap.pmtiles` and `map.meta.json`). Style assets from `family/map_assets/` are rsync’d into the data directory on every run (without deleting the basemap or metadata).

Map files are chmod `644` and directories `755`; when run as root, ownership is set to `www-data` (the family dashboard systemd user).

## On-disk layout

Default data directory: `/var/lib/tinywebstack/map/`

| File | Purpose |
|------|---------|
| `basemap.pmtiles` | Protomaps vector extract |
| `map.meta.json` | `bounds`, `maxzoom`, `flavor` |
| `fonts/`, `sprites/`, `style.json` | Rendering assets (from repo `family/map_assets/`) |

## API and access control

- `GET /family/api/map` — parent-only (kids get 403). Returns `available`, `tiles_url`, `glyphs_url`, `sprites_url`, `style_url`, `bounds`, `maxzoom`, `attribution`.
- `GET /family/tiles/...` — parent auth via device **Bearer** token or signed `?t=` query (minted in `/api/map`) for glyph/sprite fetches; SSO works for browser sessions.

Attribution shown in the app: **© OpenStreetMap contributors, Protomaps**.

## Licenses

| Component | License |
|-----------|---------|
| [go-pmtiles](https://github.com/protomaps/go-pmtiles) | BSD-3-Clause |
| [flutter_map](https://github.com/fleaflet/flutter_map) | BSD-3-Clause |
| [vector_map_tiles](https://github.com/josxha/flutter_map_plugins) | BSD-3-Clause |
| Protomaps basemap themes/sprites (bundled) | CC0 / public domain |
| OSM data (inside extract) | ODbL (attribution required) |
