"""Self-hosted Protomaps PMTiles basemap configuration."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Optional, Tuple

ATTRIBUTION = "© OpenStreetMap contributors, Protomaps"

DEFAULT_MAP_DATA_DIR = "/var/lib/tinywebstack/map"
DEFAULT_FLAVOR = "light"
DEFAULT_MAX_ZOOM = 14


@dataclass(frozen=True)
class MapBasemapConfig:
    available: bool
    bounds: Optional[List[float]]
    maxzoom: int
    flavor: str
    attribution: str = ATTRIBUTION
    tiles_path: str = "basemap.pmtiles"
    glyphs_path: str = "fonts/{fontstack}/{range}.pbf"
    sprites_path: str = "sprites/v4/light"

    def to_api_dict(self, public_base_url: str, assets_query: str) -> dict[str, Any]:
        base = _site_origin(public_base_url)
        q = f"?{assets_query}" if assets_query else ""
        tiles_url = f"{base}/family/tiles/{self.tiles_path}{q}"
        glyphs_url = f"{base}/family/tiles/{self.glyphs_path}{q}"
        sprites_url = f"{base}/family/tiles/{self.sprites_path}{q}"
        style_url = f"{base}/family/tiles/style.json{q}"
        out: dict[str, Any] = {
            "available": self.available,
            "attribution": self.attribution,
            "maxzoom": self.maxzoom,
            "flavor": self.flavor,
            "tiles_url": tiles_url,
            "glyphs_url": glyphs_url,
            "sprites_url": sprites_url,
            "style_url": style_url,
        }
        if self.bounds is not None:
            out["bounds"] = self.bounds
        return out


def _map_data_dir() -> Path:
    return Path(os.environ.get("TWS_MAP_DATA_DIR", DEFAULT_MAP_DATA_DIR))


def _read_meta(data_dir: Path) -> dict[str, Any]:
    meta_path = data_dir / "map.meta.json"
    if not meta_path.is_file():
        return {}
    try:
        return json.loads(meta_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _parse_bbox(raw: Optional[str]) -> Optional[List[float]]:
    if not raw or not str(raw).strip():
        return None
    parts = [p.strip() for p in str(raw).split(",")]
    if len(parts) != 4:
        return None
    try:
        vals = [float(p) for p in parts]
    except ValueError:
        return None
    minlon, minlat, maxlon, maxlat = vals
    if minlon >= maxlon or minlat >= maxlat:
        return None
    return [minlon, minlat, maxlon, maxlat]


def _site_origin(public_base_url: str) -> str:
    base = public_base_url.rstrip("/")
    if base.endswith("/family"):
        return base[: -len("/family")]
    return base


def load_map_config() -> MapBasemapConfig:
    data_dir = _map_data_dir()
    pmtiles = data_dir / "basemap.pmtiles"
    meta = _read_meta(data_dir)
    bounds = meta.get("bounds")
    if isinstance(bounds, list) and len(bounds) == 4:
        try:
            bounds = [float(x) for x in bounds]
        except (TypeError, ValueError):
            bounds = None
    else:
        bounds = _parse_bbox(os.environ.get("TWS_MAP_BBOX"))
    maxzoom = int(meta.get("maxzoom") or os.environ.get("TWS_MAP_MAXZOOM") or DEFAULT_MAX_ZOOM)
    flavor = str(meta.get("flavor") or os.environ.get("TWS_MAP_FLAVOR") or DEFAULT_FLAVOR)
    sprites_path = meta.get("sprites_path")
    if not isinstance(sprites_path, str) or not sprites_path.strip():
        sprites_path = f"sprites/v4/{flavor}"
    available = pmtiles.is_file() and pmtiles.stat().st_size > 0 and bounds is not None
    return MapBasemapConfig(
        available=available,
        bounds=bounds if available else None,
        maxzoom=maxzoom,
        flavor=flavor,
        sprites_path=sprites_path,
    )


def resolve_tile_path(relative: str) -> Optional[Path]:
    """Resolve a path under the map data dir; reject traversal."""
    data_dir = _map_data_dir().resolve()
    rel = relative.lstrip("/").replace("\\", "/")
    if ".." in rel.split("/"):
        return None
    candidate = (data_dir / rel).resolve()
    try:
        candidate.relative_to(data_dir)
    except ValueError:
        return None
    if not candidate.is_file():
        return None
    return candidate
