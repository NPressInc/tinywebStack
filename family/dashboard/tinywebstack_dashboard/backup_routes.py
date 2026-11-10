"""Parent-only backup pages. Every route requires a parent SSO session."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import RedirectResponse, StreamingResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import BadSignature, URLSafeSerializer

from tinywebstack_dashboard.auth import DashboardConfig, require_parent, username_from_headers
from tinywebstack_dashboard.backup import (
    BackupError,
    active_job,
    connect,
    coverage_rows,
    human_bytes,
    insert_job,
    list_jobs,
    load_settings,
    phase_label,
    reconcile_jobs,
    redact,
    require_archive_id,
    save_settings,
    summary_text,
    update_job,
    validate_export_path,
    validate_settings,
    has_succeeded_backup,
)
from tinywebstack_dashboard.urls import dash_url, dashboard_root_path

TEMPLATES = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
TEMPLATES.env.globals["url"] = lambda path="/": dash_url(path)
_HELPER_DEFAULT = Path("/usr/local/sbin/tws-family-backup-privileged")


def helper_command() -> Optional[List[str]]:
    raw = os.environ.get("TWS_BACKUP_HELPER", "").strip()
    if raw:
        return raw.split()
    if _HELPER_DEFAULT.is_file():
        return ["sudo", str(_HELPER_DEFAULT)]
    return None


def _no_store(response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


def create_backup_router(cfg: DashboardConfig) -> APIRouter:
    router = APIRouter()
    serializer = URLSafeSerializer(cfg.csrf_secret or secrets.token_hex(16), salt="tws-csrf")

    def current_user(request: Request) -> str:
        user = username_from_headers(dict(request.headers))
        require_parent(user, cfg)
        return user  # type: ignore[return-value]

    def csrf_token() -> str:
        return serializer.dumps({"n": secrets.token_hex(8)})

    def check_csrf(token: str) -> None:
        try:
            serializer.loads(token or "")
        except BadSignature as exc:
            raise HTTPException(status_code=400, detail="Invalid CSRF token") from exc

    def call_helper(args: List[str], timeout: float = 8) -> subprocess.CompletedProcess[str]:
        cmd = helper_command()
        if not cmd:
            raise BackupError("Backup tools are not installed on this box yet.")
        try:
            return subprocess.run(
                [*cmd, *args],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BackupError("Backup tools did not answer.") from exc

    def spawn_helper(args: List[str]) -> None:
        cmd = helper_command()
        if not cmd:
            raise BackupError("Backup tools are not installed on this box yet.")
        subprocess.Popen(  # noqa: S603 - argv is the fixed helper plus a validated id
            [*cmd, *args],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def page(
        request: Request,
        user: str,
        *,
        error: str = "",
        status_code: int = 200,
    ):
        settings = load_settings()
        jobs: List[Dict[str, Any]] = []
        free_text = "Free space will show here once backup tools are installed."
        low_space = False
        helper_ready = helper_command() is not None
        sizes: Dict[str, int] = {}
        size_note = ""
        try:
            conn = connect()
        except OSError:
            conn = None
        if conn is not None:
            try:
                reconcile_jobs(conn)
                jobs = list_jobs(conn)
            finally:
                conn.close()
        if helper_ready:
            try:
                pre = call_helper(["preflight"])
                if pre.returncode == 0:
                    payload = json.loads(pre.stdout or "{}")
                    free = int(payload.get("free_bytes", 0))
                    needed = int(payload.get("min_free_bytes", 0))
                    low_space = not bool(payload.get("ok"))
                    size_note = str(payload.get("size_note") or "")
                    free_text = (
                        f"{human_bytes(free)} free on the disk that holds backups. "
                        f"A backup starts only when at least {human_bytes(needed)} is free."
                    )
            except (BackupError, json.JSONDecodeError, TypeError, ValueError):
                free_text = "Could not check free space."
            try:
                listed = call_helper(["list-archives"])
                if listed.returncode == 0:
                    body = json.loads(listed.stdout or "{}")
                    for item in body.get("archives") or []:
                        if isinstance(item, dict) and item.get("id"):
                            sizes[str(item["id"])] = int(item.get("bytes") or 0)
            except (BackupError, json.JSONDecodeError, TypeError, ValueError):
                pass
        view_jobs = []
        running = False
        for job in jobs:
            detail = redact(job.get("detail") or "")
            view_jobs.append(
                {
                    **job,
                    "detail": detail,
                    "phase_label": phase_label(job.get("phase") or ""),
                    "summary_text": summary_text(job.get("summary") or ""),
                    "size_text": human_bytes(sizes.get(job.get("archive_id") or ""))
                    if job.get("archive_id") in sizes
                    else "",
                    "downloadable": job.get("status") == "succeeded"
                    and job.get("kind") == "backup"
                    and job.get("archive_id") in sizes,
                }
            )
            if job.get("status") in {"queued", "running"}:
                running = True
        response = TEMPLATES.TemplateResponse(
            request,
            "backup.html",
            {
                "user": user,
                "csrf": csrf_token(),
                "error": redact(error) if error else "",
                "settings": settings,
                "jobs": view_jobs,
                "coverage": coverage_rows(),
                "free_text": free_text,
                "size_note": size_note,
                "low_space": low_space,
                "helper_ready": helper_ready,
                "running": running,
                "server_name": cfg.server_name,
                "min_free_gb": max(1, settings.min_free_bytes // (1024 * 1024 * 1024)),
            },
            status_code=status_code,
        )
        return _no_store(response)

    @router.get("/backup")
    async def backup_page(request: Request, user: str = Depends(current_user)):
        return page(request, user)

    @router.post("/backup/now")
    async def backup_now(
        request: Request,
        user: str = Depends(current_user),
        csrf: str = Form(""),
    ):
        check_csrf(csrf)
        if helper_command() is None:
            return page(
                request,
                user,
                error="Backup tools are not installed on this box yet. Nothing was backed up.",
                status_code=503,
            )
        try:
            pre = call_helper(["preflight"])
            payload = json.loads(pre.stdout or "{}") if pre.returncode == 0 else {}
        except (BackupError, json.JSONDecodeError):
            payload = {}
        if not payload.get("ok", False):
            return page(
                request,
                user,
                error="Not enough free disk space, so no backup was started.",
                status_code=409,
            )
        conn = connect()
        try:
            if active_job(conn):
                return page(
                    request,
                    user,
                    error="Another backup is already running.",
                    status_code=409,
                )
            job = insert_job(conn, kind="backup", actor=user)
            job_id = job["id"]
        finally:
            conn.close()
        try:
            spawn_helper(["run-backup", job_id])
        except BackupError:
            conn = connect()
            try:
                update_job(
                    conn,
                    job_id,
                    status="failed",
                    phase="failed",
                    detail="Backup tools are not installed on this box yet.",
                )
            finally:
                conn.close()
            return page(request, user, error="Backup did not start.", status_code=503)
        root = dashboard_root_path()
        return _no_store(RedirectResponse(url=dash_url("/backup", root), status_code=303))

    @router.post("/backup/settings")
    async def backup_settings(
        request: Request,
        user: str = Depends(current_user),
        csrf: str = Form(""),
        frequency: str = Form("off"),
        hour: str = Form("3"),
        minute: str = Form("15"),
        weekday: str = Form("6"),
        keep_last: str = Form("3"),
        max_age_days: str = Form("90"),
        min_free_gb: str = Form("2"),
    ):
        check_csrf(csrf)
        try:
            settings = validate_settings(
                {
                    "frequency": frequency,
                    "hour": hour,
                    "minute": minute,
                    "weekday": weekday,
                    "keep_last": keep_last,
                    "max_age_days": max_age_days,
                    "min_free_gb": min_free_gb,
                }
            )
        except BackupError as exc:
            return page(request, user, error=str(exc), status_code=400)
        previous = load_settings()
        if settings.frequency != "off" and helper_command() is None:
            return page(
                request,
                user,
                error="Automatic backups stay off until backup tools are installed.",
                status_code=503,
            )
        save_settings(settings)
        if helper_command() is not None:
            try:
                result = call_helper(["apply-schedule"], timeout=30)
            except BackupError:
                result = None
            if result is None or result.returncode != 0:
                save_settings(previous)
                if settings.frequency == "off":
                    message = "Could not turn off automatic backups. The previous schedule is unchanged."
                else:
                    message = "Could not turn on automatic backups. The previous schedule is unchanged."
                return page(request, user, error=message, status_code=502)
        root = dashboard_root_path()
        return _no_store(RedirectResponse(url=dash_url("/backup", root), status_code=303))

    @router.post("/backup/archives/{archive_id}/download")
    async def download_archive(
        archive_id: str,
        user: str = Depends(current_user),
        csrf: str = Form(""),
    ):
        del user
        check_csrf(csrf)
        try:
            require_archive_id(archive_id)
        except BackupError as exc:
            raise HTTPException(status_code=400, detail="Unknown backup.") from exc
        conn = connect()
        try:
            if not has_succeeded_backup(conn, archive_id):
                raise HTTPException(status_code=404, detail="Unknown backup.")
        finally:
            conn.close()
        cmd = helper_command()
        if not cmd:
            raise HTTPException(status_code=503, detail="Backup tools are not installed.")
        proc = subprocess.Popen(  # noqa: S603
            [*cmd, "cat-archive", archive_id],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert proc.stdout is not None
        first = proc.stdout.read(1)
        if not first:
            err = b""
            if proc.stderr is not None:
                err = proc.stderr.read(400)
            proc.wait(timeout=10)
            raise HTTPException(status_code=404, detail=redact(err.decode("utf-8", errors="replace")) or "Unknown backup.")

        def body():
            try:
                yield first
                while True:
                    chunk = proc.stdout.read(1024 * 1024)  # type: ignore[union-attr]
                    if not chunk:
                        break
                    yield chunk
            finally:
                if proc.stdout:
                    proc.stdout.close()
                if proc.stderr:
                    proc.stderr.close()
                proc.wait(timeout=60)

        response = StreamingResponse(body(), media_type="application/x-tar")
        response.headers["Content-Disposition"] = f'attachment; filename="{archive_id}.tar"'
        return _no_store(response)

    @router.post("/backup/archives/{archive_id}/copy")
    async def copy_archive(
        request: Request,
        archive_id: str,
        user: str = Depends(current_user),
        csrf: str = Form(""),
        destination: str = Form(""),
    ):
        check_csrf(csrf)
        try:
            require_archive_id(archive_id)
            dest = validate_export_path(destination)
        except BackupError as exc:
            return page(request, user, error=str(exc), status_code=400)
        conn = connect()
        try:
            if not has_succeeded_backup(conn, archive_id):
                return page(request, user, error="Unknown backup.", status_code=404)
            if active_job(conn):
                return page(request, user, error="Another backup is already running.", status_code=409)
            job = insert_job(
                conn,
                kind="copy",
                actor=user,
                archive_id=archive_id,
                export_path=dest,
            )
            job_id = job["id"]
        finally:
            conn.close()
        try:
            spawn_helper(["copy-archive", job_id])
        except BackupError:
            conn = connect()
            try:
                update_job(conn, job_id, status="failed", phase="failed", detail="Copy did not start.")
            finally:
                conn.close()
            return page(request, user, error="Copy did not start.", status_code=503)
        root = dashboard_root_path()
        return _no_store(RedirectResponse(url=dash_url("/backup", root), status_code=303))

    return router
