"""Serve self-hosted map tiles and assets (parent auth)."""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import FileResponse

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    api_user,
    require_parent_user,
    user_in_group,
)
from tinywebstack_dashboard.map_assets import token_from_query, username_from_map_assets_token
from tinywebstack_dashboard.map_config import load_map_config, resolve_tile_path


def _authorize_map_assets(request: Request, cfg: DashboardConfig) -> str:
    """Bearer/SSO parent auth, or signed ?t= token minted by GET /api/map."""
    query_token = token_from_query(dict(request.query_params))
    if query_token:
        username = username_from_map_assets_token(query_token)
        if username and user_in_group(username, cfg.parents_group, cfg.yunohost_cli):
            return username
        raise HTTPException(status_code=403, detail="Invalid map asset token")
    auth = api_user(request, cfg)
    require_parent_user(auth, cfg)
    return auth.username


def create_map_router(cfg: DashboardConfig) -> APIRouter:
    router = APIRouter()

    @router.get("/tiles/{path:path}")
    async def serve_map_tile(path: str, request: Request):
        _authorize_map_assets(request, cfg)
        resolved = resolve_tile_path(path)
        if resolved is None:
            raise HTTPException(status_code=404, detail="Not found")
        return FileResponse(
            resolved,
            media_type=_media_type(resolved),
            headers={"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600"},
        )

    @router.get("/api/map/tiles-auth")
    async def map_tiles_auth(request: Request):
        """Nginx auth_request subrequest — 200 only for authorized parents."""
        _authorize_map_assets(request, cfg)
        return Response(status_code=200)

    return router


def _media_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".pmtiles":
        return "application/vnd.pmtiles"
    if suffix == ".pbf":
        return "application/x-protobuf"
    if suffix == ".json":
        return "application/json"
    if suffix in (".png", ".webp"):
        return f"image/{suffix.lstrip('.')}"
    return "application/octet-stream"
