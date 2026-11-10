"""Parent-only, read-only health checks for the family home.

Checks are cheap and bounded: loopback HTTP, one ``systemctl show`` of a fixed
unit list, certificate dates, and ``df`` of ``/``. Nothing here restarts a
service, runs a shell string, or copies tokens, log lines, or filesystem paths
into the parent-facing report.
"""

from __future__ import annotations

import json
import os
import re
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable, Dict, List, Optional
from urllib.parse import urlparse

from fastapi import Depends, FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse

from tinywebstack_dashboard.auth import (
    DashboardConfig,
    api_user,
    require_parent,
    require_parent_user,
    username_from_headers,
)
from tinywebstack_dashboard.jellyfin import jellyfin_public_discovery
from tinywebstack_dashboard.peer_verify import _ssl_context

STATUS_OK = "ok"
STATUS_WARNING = "warning"
STATUS_PROBLEM = "problem"
STATUS_NOT_INSTALLED = "not_installed"
_STATUSES = {STATUS_OK, STATUS_WARNING, STATUS_PROBLEM, STATUS_NOT_INSTALLED}

CHECK_ORDER = (
    "synapse",
    "calendars",
    "events",
    "location",
    "push",
    "web",
    "disk",
    "jellyfin",
    "backups",
)

HTTP_TIMEOUT_S = 2.0
COMMAND_TIMEOUT_S = 2.0
BUDGET_S = 3.5
CERT_WARN = timedelta(days=14)
DISK_WARN_BYTES = 5 * 1024 ** 3
DISK_PROBLEM_BYTES = 1 * 1024 ** 3

_HOST_RE = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"
)
_LEAK_RE = re.compile(
    r"(?i)(bearer\s+\S+|tws_[a-z0-9]+|/(?:etc|var|opt|home|root|usr|proc|sys)/\S+"
    r"|127\.0\.0\.1(?::\d+)?|\blocalhost\b(?::\d+)?|(?:password|token|api_key)\s*[=:]\s*\S+)"
)

ALLOWED_UNITS = frozenset(
    {
        "synapse",
        "matrix-synapse",
        "mobilizon",
        "owntracks",
        "ot-recorder",
        "traccar",
        "tinywebstack-sygnal",
        "sygnal",
        "tinywebstack-ntfy",
        "jellyfin",
        "tinywebstack-backup.service",
        "tinywebstack-backup.timer",
        "borgmatic.service",
        "borgmatic.timer",
        "restic-backup.service",
        "restic-backup.timer",
    }
)

_BACKUP_UNITS = (
    "tinywebstack-backup.service",
    "tinywebstack-backup.timer",
    "borgmatic.service",
    "borgmatic.timer",
    "restic-backup.service",
    "restic-backup.timer",
)
_JELLYFIN_DIR = "/etc/yunohost/apps/jellyfin"
_BACKUP_FILES = (
    "/etc/tinywebstack/backup.env",
    "/etc/tinywebstack/backup.json",
    "/etc/tinywebstack/backups.json",
)
_CERT_DIR = "/etc/yunohost/certs"

_HINT_CHAT = (
    "Try sending a message in the TinyWeb app. If chat stays down, ask the person "
    "who set up this home to check the chat service. This page will not restart it."
)
_HINT_CAL = (
    "Open Calendar in the TinyWeb app and refresh. If calendars stay down, ask the "
    "person who set up this home to check them. This page will not restart anything."
)
_HINT_EVENTS = (
    "Open Events in the TinyWeb app and try again. If events stay down, ask the "
    "person who set up this home to check them. This page will not restart anything."
)
_HINT_LOC = (
    "Ask family phones to open TinyWeb so they can share location again. If this "
    "stays down, ask the person who set up this home to check location. This page "
    "will not restart it."
)
_HINT_PUSH = (
    "Phones may not buzz for new messages until this is fixed. Ask the person who "
    "set up this home to check notifications. This page will not restart them."
)
_HINT_STUB = (
    "Apple phones will not buzz until notification setup is finished. Android phones "
    "may still get alerts. This page cannot finish that setup."
)
_HINT_WEB = (
    "Ask the person who set up this home to renew the website certificate or check "
    "that the family web address answers. This page cannot renew it."
)
_HINT_DISK = "Free some space on the home server so chat and photos keep working."
_HINT_OPTIONAL = "This is optional. Nothing to fix."
_HINT_JELLY = (
    "Open the Jellyfin app again in a minute. If it stays down, ask the person who "
    "set up this home to check movies and TV. This page will not restart it."
)
_HINT_BACKUP = (
    "Ask the person who set up this home to turn backups on. This page will not start them."
)
_HINT_AGAIN = "Wait a minute and check again. This page did not change anything."


def sanitize(text: str) -> str:
    """Drop secrets and internal paths from a parent-facing sentence."""
    if not isinstance(text, str):
        return ""
    cleaned = "".join(ch for ch in text if ch == "\n" or ord(ch) >= 32)
    cleaned = _LEAK_RE.sub("…", cleaned)
    if len(cleaned) > 400:
        cleaned = cleaned[:400].rstrip()
    return cleaned.strip()


def _safe_host(host: str) -> bool:
    return bool(host) and ".." not in host and _HOST_RE.match(host) is not None


def _under_family(host: str, server_name: str) -> bool:
    root = (server_name or "").strip().lower().rstrip(".")
    host = host.strip().lower().rstrip(".")
    if not root or not _safe_host(host) or not _safe_host(root):
        return False
    return host == root or host.endswith("." + root)


def _port(env_name: str, default: int) -> int:
    raw = os.environ.get(env_name, "").strip()
    if raw.isdigit():
        value = int(raw)
        if 1 <= value <= 65535:
            return value
    return default


def push_enabled() -> bool:
    return os.environ.get("TWS_PUSH_ENABLE", "1").strip().lower() not in {"0", "false", "no", "off"}


def location_backend() -> str:
    raw = os.environ.get("LOCATION_APP", "owntracks").strip().lower()
    return "traccar" if raw == "traccar" else "owntracks"


def _loopback(url: str) -> Optional[str]:
    parsed = urlparse((url or "").strip())
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1":
        return None
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        return None
    if parsed.port is None or not (1 <= parsed.port <= 65535):
        return None
    path = parsed.path or "/"
    if not path.startswith("/") or ".." in path:
        return None
    return f"http://127.0.0.1:{parsed.port}{path}"


def public_https_url(raw: str, server_name: str) -> Optional[str]:
    parsed = urlparse((raw or "").strip())
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        return None
    if not _under_family(host, server_name):
        return None
    port = f":{parsed.port}" if parsed.port else ""
    path = parsed.path or "/"
    if not path.startswith("/") or ".." in path:
        return None
    return f"https://{host}{port}{path}"


def service_urls(cfg: DashboardConfig, *, location: str, push_on: bool) -> Dict[str, Optional[str]]:
    """Logical check name to a URL this process is allowed to fetch."""
    synapse = _loopback(
        os.environ.get("TWS_SYNAPSE_HEALTH_URL", "http://127.0.0.1:8008/_matrix/client/versions")
    ) or "http://127.0.0.1:8008/_matrix/client/versions"
    if location == "traccar":
        location_url = _loopback(
            os.environ.get("TWS_TRACCAR_HEALTH_URL", "http://127.0.0.1:8082/api/server")
        ) or "http://127.0.0.1:8082/api/server"
    else:
        base = _loopback(os.environ.get("TWS_OWNTRACKS_API_URL", "http://127.0.0.1:25959").rstrip("/") + "/")
        if base is None:
            base = "http://127.0.0.1:25959/"
        location_url = base.rstrip("/") + "/api/0/last"
    sygnal = f"http://127.0.0.1:{_port('TWS_SYGNAL_PORT', 5000)}/health" if push_on else None
    ntfy = f"http://127.0.0.1:{_port('TWS_NTFY_PORT', 8090)}/v1/health" if push_on else None
    jellyfin = _loopback(os.environ.get("TWS_JELLYFIN_HEALTH_URL", "http://127.0.0.1:8096/health"))
    jellyfin = jellyfin or "http://127.0.0.1:8096/health"
    return {
        "synapse": synapse,
        "calendars": public_https_url(cfg.caldav_root, cfg.server_name),
        "events": public_https_url(cfg.events_base_url, cfg.server_name),
        "location": location_url,
        "sygnal": sygnal,
        "ntfy": ntfy,
        "jellyfin": jellyfin,
    }


def _cert_file(host: str) -> Optional[str]:
    if not _safe_host(host):
        return None
    return f"{_CERT_DIR}/{host}/crt.pem"


def certificate_hosts(cfg: DashboardConfig, *, file_exists: Optional[Callable[[str], bool]] = None) -> List[str]:
    """Public names to check. Conventional names are included only when a cert file exists."""
    exists = file_exists or _path_exists
    hosts: List[str] = []

    def add(host: str) -> None:
        host = (host or "").strip().lower().rstrip(".")
        if host and _under_family(host, cfg.server_name) and host not in hosts:
            hosts.append(host)

    add(cfg.server_name)
    for raw in (cfg.caldav_root, cfg.events_base_url, cfg.location_base_url):
        parsed = urlparse((raw or "").strip())
        add(parsed.hostname or "")
    matrix = os.environ.get("TWS_MATRIX_SERVER", "").strip()
    if matrix and "://" not in matrix:
        add(matrix)
    server = (cfg.server_name or "").strip().lower().rstrip(".")
    if server:
        for prefix in ("matrix", "push"):
            candidate = f"{prefix}.{server}"
            path = _cert_file(candidate)
            if path and exists(path):
                add(candidate)
    discovery = jellyfin_public_discovery(os.environ.get("TWS_JELLYFIN_URL"))
    if discovery.get("enabled") and discovery.get("url"):
        add(urlparse(str(discovery["url"])).hostname or "")
    return hosts


def _path_exists(path: str) -> bool:
    if path in {_JELLYFIN_DIR, *_BACKUP_FILES} or (
        path.startswith(_CERT_DIR + "/") and path.endswith("/crt.pem") and ".." not in path
    ):
        try:
            return os.path.exists(path)
        except OSError:
            return False
    return False


@dataclass(frozen=True)
class HttpResult:
    error: str = ""
    status_code: Optional[int] = None
    body: str = ""


@dataclass(frozen=True)
class UnitState:
    installed: bool = False
    active: bool = False


@dataclass(frozen=True)
class UnitSnapshot:
    units: Dict[str, UnitState] = field(default_factory=dict)
    timed_out: bool = False


@dataclass(frozen=True)
class CertResult:
    host: str
    reachable: bool
    expires_at: Optional[datetime] = None
    timed_out: bool = False


@dataclass(frozen=True)
class DiskResult:
    error: str = ""
    total_bytes: int = 0
    avail_bytes: int = 0


@dataclass(frozen=True)
class HealthSnapshot:
    http: Dict[str, HttpResult]
    units: UnitSnapshot
    certs: List[CertResult]
    disk: DiskResult
    optional_files: Dict[str, bool]
    location_backend: str = "owntracks"
    push_enabled: bool = True


@dataclass(frozen=True)
class HealthCheck:
    id: str
    title: str
    status: str
    summary: str
    hint: str
    checked_at: str


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def checked_label(iso: str) -> str:
    try:
        moment = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return "just now"
    return moment.strftime("%d %b %Y, %H:%M UTC").lstrip("0")


def _check(check_id: str, title: str, status: str, summary: str, hint: str, checked_at: str) -> HealthCheck:
    if status not in _STATUSES:
        status = STATUS_PROBLEM
    return HealthCheck(
        id=check_id,
        title=sanitize(title) or title,
        status=status,
        summary=sanitize(summary),
        hint=sanitize(hint),
        checked_at=checked_at,
    )


def _unit(snapshot: HealthSnapshot, *names: str) -> tuple[bool, bool]:
    installed = False
    active = False
    for name in names:
        state = snapshot.units.units.get(name)
        if state and state.installed:
            installed = True
            active = active or state.active
    return installed, active


def _http_kind(result: Optional[HttpResult], ok_codes: set[int]) -> str:
    if result is None or result.error == "unconfigured":
        return "unconfigured"
    if result.error == "timeout":
        return "timeout"
    if result.error == "tls":
        return "tls"
    if result.error == "unreachable":
        return "unreachable"
    code = result.status_code
    if code in ok_codes:
        return "ok"
    if code is not None and code >= 500:
        return "http_problem"
    return "http_warning"


def _required(
    *,
    check_id: str,
    title: str,
    kind: str,
    installed: bool,
    active: bool,
    units_timed_out: bool,
    checked_at: str,
    hint: str,
    missing: str,
    plural: bool = False,
) -> HealthCheck:
    be = "are" if plural else "is"
    if kind == "ok":
        return _check(check_id, title, STATUS_OK, f"{title} {be} working.", "", checked_at)
    if kind == "timeout" or (kind == "unreachable" and units_timed_out and not installed):
        return _check(
            check_id,
            title,
            STATUS_PROBLEM,
            f"{title} did not answer in time.",
            _HINT_AGAIN,
            checked_at,
        )
    if kind == "tls":
        return _check(
            check_id,
            title,
            STATUS_PROBLEM,
            f"{title} could not be checked because the security certificate was not trusted.",
            hint,
            checked_at,
        )
    if kind == "unconfigured" or (kind == "unreachable" and not installed):
        return _check(check_id, title, STATUS_PROBLEM, missing, hint, checked_at)
    if kind == "unreachable" and installed and not active:
        return _check(check_id, title, STATUS_PROBLEM, f"{title} {be} switched off.", hint, checked_at)
    if kind == "http_warning":
        return _check(
            check_id,
            title,
            STATUS_WARNING,
            f"{title} answered, but not in the usual way.",
            hint,
            checked_at,
        )
    return _check(check_id, title, STATUS_PROBLEM, f"{title} {be} not answering.", hint, checked_at)


def _is_stub(body: str) -> bool:
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return False
    return isinstance(data, dict) and data.get("mode") == "stub"


def map_synapse(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    result = snapshot.http.get("synapse")
    installed, active = _unit(snapshot, "synapse", "matrix-synapse")
    kind = _http_kind(result, {200})
    if kind == "ok" and (result is None or "versions" not in (result.body or "").lower()):
        return _check(
            "synapse",
            "Chat",
            STATUS_WARNING,
            "Chat answered, but not in the usual way.",
            _HINT_CHAT,
            checked_at,
        )
    return _required(
        check_id="synapse",
        title="Chat",
        kind=kind,
        installed=installed,
        active=active,
        units_timed_out=snapshot.units.timed_out,
        checked_at=checked_at,
        hint=_HINT_CHAT,
        missing="Chat is not set up on this home.",
    )


def map_calendars(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    result = snapshot.http.get("calendars")
    kind = _http_kind(result, {200, 207, 401})
    return _required(
        check_id="calendars",
        title="Calendars",
        kind=kind,
        installed=kind != "unconfigured",
        active=True,
        units_timed_out=False,
        checked_at=checked_at,
        hint=_HINT_CAL,
        missing="Calendars are not set up on this home.",
        plural=True,
    )


def map_events(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    result = snapshot.http.get("events")
    installed, active = _unit(snapshot, "mobilizon")
    kind = _http_kind(result, {200, 301, 302, 303, 307, 308, 401})
    if kind == "unconfigured":
        installed = False
    return _required(
        check_id="events",
        title="Events",
        kind=kind,
        installed=installed or kind == "ok",
        active=active or kind == "ok",
        units_timed_out=snapshot.units.timed_out,
        checked_at=checked_at,
        hint=_HINT_EVENTS,
        missing="Events are not set up on this home.",
        plural=True,
    )


def map_location(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    result = snapshot.http.get("location")
    if snapshot.location_backend == "traccar":
        installed, active = _unit(snapshot, "traccar")
        ok_codes = {200, 401}
    else:
        installed, active = _unit(snapshot, "owntracks", "ot-recorder")
        ok_codes = {200}
    kind = _http_kind(result, ok_codes)
    return _required(
        check_id="location",
        title="Location",
        kind=kind,
        installed=installed,
        active=active,
        units_timed_out=snapshot.units.timed_out,
        checked_at=checked_at,
        hint=_HINT_LOC,
        missing="Location is not set up on this home.",
    )


def map_push(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    if not snapshot.push_enabled:
        return _check(
            "push",
            "Phone notifications",
            STATUS_NOT_INSTALLED,
            "Not installed.",
            "Phone notifications are turned off for this home. Nothing to fix.",
            checked_at,
        )
    result = snapshot.http.get("sygnal") or HttpResult(error="unreachable")
    installed, active = _unit(snapshot, "tinywebstack-sygnal", "sygnal")
    kind = _http_kind(result, {200})
    base = _required(
        check_id="push",
        title="Phone notifications",
        kind=kind,
        installed=installed,
        active=active,
        units_timed_out=snapshot.units.timed_out,
        checked_at=checked_at,
        hint=_HINT_PUSH,
        missing="Phone notifications are not set up on this home.",
        plural=True,
    )
    ntfy_installed, _ntfy_active = _unit(snapshot, "tinywebstack-ntfy")
    ntfy_kind = _http_kind(snapshot.http.get("ntfy"), {200})
    if base.status == STATUS_OK and _is_stub(result.body):
        summary = "Phone notifications are only partly set up."
        if ntfy_installed and ntfy_kind != "ok":
            summary = "Phone notifications are only partly set up, and Android notifications are not answering."
        return _check("push", "Phone notifications", STATUS_WARNING, summary, _HINT_STUB, checked_at)
    if base.status == STATUS_OK and ntfy_installed and ntfy_kind == "timeout":
        return _check(
            "push",
            "Phone notifications",
            STATUS_WARNING,
            "Android notifications did not answer in time.",
            _HINT_PUSH,
            checked_at,
        )
    if base.status == STATUS_OK and ntfy_installed and ntfy_kind != "ok":
        return _check(
            "push",
            "Phone notifications",
            STATUS_WARNING,
            "Android notifications are not answering.",
            _HINT_PUSH,
            checked_at,
        )
    return base


def _display_host(host: str) -> str:
    cleaned = (host or "").strip().lower().rstrip(".")
    if _safe_host(cleaned) and _LEAK_RE.search(cleaned) is None:
        return cleaned
    return "A family address"


def _expiry_phrase(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%d %b %Y").lstrip("0")


def map_web(snapshot: HealthSnapshot, checked_at: str, now: datetime) -> HealthCheck:
    if not snapshot.certs:
        return _check(
            "web",
            "Website and certificate",
            STATUS_PROBLEM,
            "This home has no web address to check.",
            _HINT_WEB,
            checked_at,
        )
    notes: List[tuple[str, str]] = []
    for cert in snapshot.certs:
        host = _display_host(cert.host)
        expires = cert.expires_at
        if expires is not None and expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
        if cert.timed_out:
            notes.append((STATUS_PROBLEM, f"{host} did not answer in time."))
            continue
        if not cert.reachable:
            if expires is not None and expires <= now:
                notes.append((STATUS_PROBLEM, f"{host} could not be reached, and its certificate has expired."))
            elif expires is not None and expires <= now + CERT_WARN:
                notes.append(
                    (STATUS_PROBLEM, f"{host} could not be reached. Its certificate expires on {_expiry_phrase(expires)}.")
                )
            else:
                notes.append((STATUS_PROBLEM, f"{host} could not be reached."))
            continue
        if expires is None:
            notes.append((STATUS_WARNING, f"{host} answered, but the certificate date could not be read."))
        elif expires <= now:
            notes.append((STATUS_PROBLEM, f"The certificate for {host} has expired."))
        elif expires <= now + CERT_WARN:
            notes.append((STATUS_WARNING, f"The certificate for {host} expires on {_expiry_phrase(expires)}."))
        else:
            notes.append((STATUS_OK, ""))
    worst = STATUS_OK
    for status, _line in notes:
        if status == STATUS_PROBLEM:
            worst = STATUS_PROBLEM
            break
        if status == STATUS_WARNING:
            worst = STATUS_WARNING
    if worst == STATUS_OK:
        return _check(
            "web",
            "Website and certificate",
            STATUS_OK,
            "Family web addresses answer, and certificates are valid.",
            "",
            checked_at,
        )
    lines = [line for status, line in notes if status in {STATUS_PROBLEM, STATUS_WARNING} and line]
    return _check("web", "Website and certificate", worst, " ".join(lines[:4]), _HINT_WEB, checked_at)


def _gb(num: int) -> str:
    gb = num / (1024 ** 3)
    if gb >= 10:
        return f"{gb:.0f} GB"
    return f"{gb:.1f} GB"


def map_disk(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    disk = snapshot.disk
    if disk.error == "timeout":
        return _check(
            "disk",
            "Disk space",
            STATUS_PROBLEM,
            "Disk space could not be checked in time.",
            _HINT_AGAIN,
            checked_at,
        )
    if disk.error or disk.total_bytes <= 0:
        return _check(
            "disk",
            "Disk space",
            STATUS_PROBLEM,
            "Disk space could not be checked.",
            _HINT_AGAIN,
            checked_at,
        )
    ratio = disk.avail_bytes / disk.total_bytes
    free = _gb(disk.avail_bytes)
    if ratio < 0.05 or disk.avail_bytes < DISK_PROBLEM_BYTES:
        return _check(
            "disk",
            "Disk space",
            STATUS_PROBLEM,
            f"The disk is almost full ({free} free).",
            _HINT_DISK,
            checked_at,
        )
    if ratio < 0.15 or disk.avail_bytes < DISK_WARN_BYTES:
        return _check(
            "disk",
            "Disk space",
            STATUS_WARNING,
            f"Disk space is getting low ({free} free).",
            _HINT_DISK,
            checked_at,
        )
    return _check("disk", "Disk space", STATUS_OK, f"Plenty of free space ({free} free).", "", checked_at)


def _jellyfin_installed(snapshot: HealthSnapshot) -> bool:
    unit, _active = _unit(snapshot, "jellyfin")
    if unit or snapshot.optional_files.get("jellyfin"):
        return True
    discovery = jellyfin_public_discovery(os.environ.get("TWS_JELLYFIN_URL"))
    return bool(discovery.get("enabled"))


def map_jellyfin(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    installed = _jellyfin_installed(snapshot)
    result = snapshot.http.get("jellyfin")
    kind = _http_kind(result, {200})
    if not installed:
        if snapshot.units.timed_out and kind == "timeout":
            return _check(
                "jellyfin",
                "Movies and TV",
                STATUS_WARNING,
                "Movies and TV did not answer in time.",
                _HINT_AGAIN,
                checked_at,
            )
        if snapshot.units.timed_out and kind != "ok":
            return _check(
                "jellyfin",
                "Movies and TV",
                STATUS_WARNING,
                "Could not tell whether movies and TV are installed.",
                "Check again in a minute. If you never installed movies and TV, you can ignore this.",
                checked_at,
            )
        return _check("jellyfin", "Movies and TV", STATUS_NOT_INSTALLED, "Not installed.", _HINT_OPTIONAL, checked_at)
    if kind == "ok":
        return _check("jellyfin", "Movies and TV", STATUS_OK, "Movies and TV are working.", "", checked_at)
    if kind == "timeout":
        return _check(
            "jellyfin",
            "Movies and TV",
            STATUS_PROBLEM,
            "Movies and TV did not answer in time.",
            _HINT_AGAIN,
            checked_at,
        )
    return _check("jellyfin", "Movies and TV", STATUS_PROBLEM, "Movies and TV are not answering.", _HINT_JELLY, checked_at)


def map_backups(snapshot: HealthSnapshot, checked_at: str) -> HealthCheck:
    installed_unit, active = _unit(snapshot, *_BACKUP_UNITS)
    file_present = bool(snapshot.optional_files.get("backup"))
    installed = installed_unit or file_present
    if snapshot.units.timed_out and not installed:
        return _check(
            "backups",
            "Backups",
            STATUS_WARNING,
            "Backups could not be checked in time.",
            _HINT_AGAIN,
            checked_at,
        )
    if not installed:
        return _check("backups", "Backups", STATUS_NOT_INSTALLED, "Not installed.", _HINT_OPTIONAL, checked_at)
    if active:
        return _check("backups", "Backups", STATUS_OK, "Backups are turned on.", "", checked_at)
    if file_present and not installed_unit:
        return _check(
            "backups",
            "Backups",
            STATUS_WARNING,
            "Backup settings were found, but no backup service is running.",
            _HINT_BACKUP,
            checked_at,
        )
    return _check("backups", "Backups", STATUS_PROBLEM, "Backups are installed but not running.", _HINT_BACKUP, checked_at)


def report_from_snapshot(snapshot: HealthSnapshot, now: Optional[datetime] = None) -> List[HealthCheck]:
    moment = now or _now()
    checked_at = _iso(moment)
    checks = [
        map_synapse(snapshot, checked_at),
        map_calendars(snapshot, checked_at),
        map_events(snapshot, checked_at),
        map_location(snapshot, checked_at),
        map_push(snapshot, checked_at),
        map_web(snapshot, checked_at, moment),
        map_disk(snapshot, checked_at),
        map_jellyfin(snapshot, checked_at),
        map_backups(snapshot, checked_at),
    ]
    by_id = {item.id: item for item in checks}
    return [by_id[check_id] for check_id in CHECK_ORDER if check_id in by_id]


def overall_status(checks: List[HealthCheck]) -> str:
    worst = STATUS_OK
    for item in checks:
        if item.status == STATUS_PROBLEM:
            return STATUS_PROBLEM
        if item.status == STATUS_WARNING:
            worst = STATUS_WARNING
    return worst


def unavailable_checks(now: Optional[datetime] = None) -> List[HealthCheck]:
    checked_at = _iso(now or _now())
    rows = []
    for check_id, title, optional in (
        ("synapse", "Chat", False),
        ("calendars", "Calendars", False),
        ("events", "Events", False),
        ("location", "Location", False),
        ("push", "Phone notifications", False),
        ("web", "Website and certificate", False),
        ("disk", "Disk space", False),
        ("jellyfin", "Movies and TV", True),
        ("backups", "Backups", True),
    ):
        if optional:
            rows.append(
                _check(check_id, title, STATUS_WARNING, f"{title} could not be checked.", _HINT_AGAIN, checked_at)
            )
        else:
            rows.append(
                _check(check_id, title, STATUS_PROBLEM, f"{title} could not be checked.", _HINT_AGAIN, checked_at)
            )
    return rows


def public_dict(checks: List[HealthCheck], *, cached: bool) -> dict:
    moment = checks[0].checked_at if checks else _iso(_now())
    rows = []
    for item in checks:
        if item.id not in CHECK_ORDER:
            continue
        status = item.status if item.status in _STATUSES else STATUS_PROBLEM
        rows.append(
            {
                "id": item.id,
                "title": sanitize(item.title),
                "status": status,
                "summary": sanitize(item.summary),
                "hint": sanitize(item.hint),
                "checked_at": item.checked_at if _iso_ok(item.checked_at) else moment,
            }
        )
    overall = overall_status(checks)
    if overall not in {STATUS_OK, STATUS_WARNING, STATUS_PROBLEM}:
        overall = STATUS_PROBLEM
    return {
        "overall": overall,
        "checked_at": moment if _iso_ok(moment) else _iso(_now()),
        "cached": bool(cached),
        "checks": rows,
    }


def _iso_ok(value: str) -> bool:
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return False
    return True


def summary_line(payload: Optional[dict]) -> str:
    if not payload:
        return ""
    checks = payload.get("checks") or []
    problems = sum(1 for item in checks if item.get("status") == STATUS_PROBLEM)
    warnings = sum(1 for item in checks if item.get("status") == STATUS_WARNING)
    if problems == 1:
        return "1 service needs attention"
    if problems:
        return f"{problems} services need attention"
    if warnings == 1:
        return "1 service has a warning"
    if warnings:
        return f"{warnings} services have warnings"
    return "Everything checked is working"


_STATUS_LABEL = {
    STATUS_OK: "OK",
    STATUS_WARNING: "Warning",
    STATUS_PROBLEM: "Problem",
    STATUS_NOT_INSTALLED: "Not installed",
}
_STATUS_CLASS = {
    STATUS_OK: "ok",
    STATUS_WARNING: "warning",
    STATUS_PROBLEM: "problem",
    STATUS_NOT_INSTALLED: "not-installed",
}
_OVERALL_LABEL = {
    STATUS_OK: "Everything checked is working.",
    STATUS_WARNING: "Some services need a look.",
    STATUS_PROBLEM: "Something needs attention.",
}


def view_checks(payload: dict) -> List[dict]:
    rows = []
    for item in payload.get("checks") or []:
        status = item.get("status")
        rows.append(
            {
                **item,
                "status_label": _STATUS_LABEL.get(status, "Problem"),
                "status_class": _STATUS_CLASS.get(status, "problem"),
            }
        )
    return rows


class HealthCache:
    def __init__(
        self,
        ttl_s: float = 60.0,
        min_refresh_s: float = 15.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.ttl_s = ttl_s
        self.min_refresh_s = min_refresh_s
        self._clock = clock
        self._lock = threading.Lock()
        self._payload: Optional[dict] = None
        self._at = 0.0

    def get(self, loader: Callable[[], dict], *, refresh: bool = False) -> dict:
        with self._lock:
            now = self._clock()
            fresh = self._payload is not None and (now - self._at) < self.ttl_s
            if self._payload is not None and not refresh and fresh:
                data = dict(self._payload)
                data["cached"] = True
                return data
            if self._payload is not None and refresh and (now - self._at) < self.min_refresh_s:
                data = dict(self._payload)
                data["cached"] = True
                return data
            payload = loader()
            payload = dict(payload)
            payload["cached"] = False
            self._payload = payload
            self._at = self._clock()
            return dict(payload)

    def peek(self) -> Optional[dict]:
        with self._lock:
            if self._payload is None:
                return None
            if self._clock() - self._at >= self.ttl_s:
                return None
            data = dict(self._payload)
            data["cached"] = True
            return data


def _cache_ttl() -> float:
    raw = os.environ.get("TWS_HEALTH_CACHE_SECONDS", "").strip()
    try:
        value = float(raw) if raw else 60.0
    except ValueError:
        value = 60.0
    return min(300.0, max(15.0, value))


def run_checked(argv: List[str], timeout: float, *, input_bytes: Optional[bytes] = None) -> subprocess.CompletedProcess:
    """Run one fixed read-only command. Rejects anything outside the allowlist."""
    if not argv or any(not isinstance(arg, str) or any(ch in arg for ch in "\n\r;&|$`<>\\") for arg in argv):
        raise ValueError("command not allowed")
    cmd = argv[0]
    if cmd == "systemctl":
        if len(argv) < 8 or argv[1:6] != ["show", "-p", "Id", "-p", "LoadState"] or argv[6:8] != ["-p", "ActiveState"]:
            raise ValueError("command not allowed")
        if "--" not in argv:
            raise ValueError("command not allowed")
        units = argv[argv.index("--") + 1 :]
        if not units or any(unit not in ALLOWED_UNITS for unit in units):
            raise ValueError("command not allowed")
    elif cmd == "df":
        if argv != ["df", "-P", "-B1", "/"]:
            raise ValueError("command not allowed")
    elif cmd == "openssl":
        allowed_openssl = (
            ["openssl", "x509", "-inform", "DER", "-noout", "-enddate"],
            ["openssl", "x509", "-noout", "-enddate"],
        )
        if argv not in allowed_openssl:
            raise ValueError("command not allowed")
    else:
        raise ValueError("command not allowed")
    return subprocess.run(
        argv,
        input=input_bytes,
        timeout=timeout,
        capture_output=True,
        check=False,
        shell=False,
    )


def parse_systemctl_show(text: str) -> Dict[str, UnitState]:
    found: Dict[str, UnitState] = {}
    current: Dict[str, str] = {}

    def flush() -> None:
        if not current:
            return
        unit_id = current.get("Id", "")
        name = unit_id[:-8] if unit_id.endswith(".service") else unit_id
        if name not in ALLOWED_UNITS and unit_id not in ALLOWED_UNITS:
            current.clear()
            return
        key = unit_id if unit_id in ALLOWED_UNITS else name
        load = current.get("LoadState", "")
        installed = load not in {"", "not-found", "masked"}
        active = current.get("ActiveState", "") in {"active", "reloading"}
        found[key] = UnitState(installed=installed, active=active)
        if name != key and name in ALLOWED_UNITS:
            found[name] = found[key]
        current.clear()

    for line in text.splitlines():
        if not line.strip():
            flush()
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        current[key.strip()] = value.strip()
    flush()
    return found


def parse_df(text: str) -> DiskResult:
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 2:
        return DiskResult(error="failed")
    parts = lines[1].split()
    if len(parts) < 4:
        return DiskResult(error="failed")
    try:
        total = int(parts[1])
        avail = int(parts[3])
    except ValueError:
        return DiskResult(error="failed")
    if total < 0 or avail < 0:
        return DiskResult(error="failed")
    return DiskResult(total_bytes=total, avail_bytes=avail)


def parse_openssl_enddate(text: str) -> Optional[datetime]:
    for line in text.splitlines():
        if line.startswith("notAfter="):
            raw = line.split("=", 1)[1].strip()
            if raw.endswith(" GMT"):
                raw = raw[: -len(" GMT")]
            try:
                return datetime.strptime(raw, "%b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc)
            except ValueError:
                return None
    return None


def fetch_http(url: Optional[str], timeout: float = HTTP_TIMEOUT_S, server_name: str = "") -> HttpResult:
    """GET one allowlisted URL. HTTPS must sit on this family's domain."""
    loopback = _loopback(url or "")
    https = public_https_url(url or "", server_name) if (url or "").startswith("https://") else None
    allowed = loopback or https
    if not url or allowed != url:
        return HttpResult(error="unconfigured")
    req = urllib.request.Request(url, method="GET", headers={"Accept": "*/*", "User-Agent": "tinyweb-health"})
    handlers: List[urllib.request.BaseHandler] = [urllib.request.ProxyHandler({}), _NoRedirect()]
    if url.startswith("https://"):
        handlers.append(urllib.request.HTTPSHandler(context=_ssl_context()))
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=timeout) as resp:
            body = resp.read(512).decode("utf-8", "replace")
            return HttpResult(status_code=getattr(resp, "status", None), body=body)
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(512).decode("utf-8", "replace")
        except Exception:
            body = ""
        return HttpResult(status_code=exc.code, body=body)
    except (TimeoutError, socket.timeout):
        return HttpResult(error="timeout")
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", None)
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return HttpResult(error="timeout")
        if isinstance(reason, ssl.SSLError):
            return HttpResult(error="tls")
        return HttpResult(error="unreachable")
    except ssl.SSLError:
        return HttpResult(error="tls")
    except OSError:
        return HttpResult(error="unreachable")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        return None


def fetch_units(timeout: float = COMMAND_TIMEOUT_S) -> UnitSnapshot:
    argv = [
        "systemctl",
        "show",
        "-p",
        "Id",
        "-p",
        "LoadState",
        "-p",
        "ActiveState",
        "--",
        *sorted(ALLOWED_UNITS),
    ]
    try:
        proc = run_checked(argv, timeout)
    except subprocess.TimeoutExpired:
        return UnitSnapshot(timed_out=True)
    except (FileNotFoundError, ValueError, OSError):
        return UnitSnapshot()
    stdout = proc.stdout.decode("utf-8", "replace") if isinstance(proc.stdout, bytes) else proc.stdout
    text = stdout or ""
    # A failed systemctl (no systemd bus) must not be read as "nothing is installed".
    if proc.returncode != 0 and not text.strip():
        return UnitSnapshot(timed_out=True)
    return UnitSnapshot(units=parse_systemctl_show(text))


def fetch_disk(timeout: float = COMMAND_TIMEOUT_S) -> DiskResult:
    try:
        proc = run_checked(["df", "-P", "-B1", "/"], timeout)
    except subprocess.TimeoutExpired:
        return DiskResult(error="timeout")
    except (FileNotFoundError, ValueError, OSError):
        return DiskResult(error="failed")
    stdout = proc.stdout.decode("utf-8", "replace") if isinstance(proc.stdout, bytes) else proc.stdout
    return parse_df(stdout or "")


def _peer_der(host: str, timeout: float) -> bytes:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, 443), timeout) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            der = tls.getpeercert(binary_form=True)
    if not der:
        raise OSError("no certificate")
    return der


def _local_expiry(host: str) -> Optional[datetime]:
    path = _cert_file(host)
    if not path or not _safe_host(host) or not _path_exists(path):
        return None
    pem = _read_cert_pem(path)
    if not pem:
        return None
    try:
        proc = run_checked(
            ["openssl", "x509", "-noout", "-enddate"],
            COMMAND_TIMEOUT_S,
            input_bytes=pem,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError, OSError):
        return None
    stdout = proc.stdout.decode("ascii", "replace") if isinstance(proc.stdout, bytes) else ""
    return parse_openssl_enddate(stdout)


def _read_cert_pem(path: str) -> bytes:
    if not path.startswith(_CERT_DIR + "/") or not path.endswith("/crt.pem") or ".." in path:
        return b""
    try:
        with open(path, "rb") as handle:
            data = handle.read(8192)
    except OSError:
        return b""
    if b"PRIVATE" in data or b"-----BEGIN CERTIFICATE-----" not in data:
        return b""
    return data


def fetch_cert(host: str, timeout: float = HTTP_TIMEOUT_S) -> CertResult:
    if not _safe_host(host):
        return CertResult(host="invalid", reachable=False)
    try:
        der = _peer_der(host, timeout)
    except (TimeoutError, socket.timeout):
        return CertResult(host=host, reachable=False, timed_out=True, expires_at=_local_expiry(host))
    except OSError:
        return CertResult(host=host, reachable=False, expires_at=_local_expiry(host))
    try:
        proc = run_checked(
            ["openssl", "x509", "-inform", "DER", "-noout", "-enddate"],
            COMMAND_TIMEOUT_S,
            input_bytes=der,
        )
    except subprocess.TimeoutExpired:
        return CertResult(host=host, reachable=True, timed_out=False, expires_at=None)
    except (FileNotFoundError, ValueError, OSError):
        return CertResult(host=host, reachable=True, expires_at=None)
    stdout = proc.stdout.decode("ascii", "replace") if isinstance(proc.stdout, bytes) else ""
    return CertResult(host=host, reachable=True, expires_at=parse_openssl_enddate(stdout))


def optional_markers() -> Dict[str, bool]:
    return {
        "jellyfin": _path_exists(_JELLYFIN_DIR),
        "backup": any(_path_exists(path) for path in _BACKUP_FILES),
    }


class LiveHealthProbes:
    def snapshot(self, cfg: DashboardConfig) -> HealthSnapshot:
        backend = location_backend()
        push_on = push_enabled()
        urls = service_urls(cfg, location=backend, push_on=push_on)
        hosts = certificate_hosts(cfg)
        http: Dict[str, HttpResult] = {}
        certs: List[CertResult] = []
        units = UnitSnapshot()
        disk = DiskResult(error="failed")
        pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="tws-health")
        try:
            http_futs = {
                pool.submit(fetch_http, url, HTTP_TIMEOUT_S, cfg.server_name): key
                for key, url in urls.items()
                if url
            }
            cert_futs = {pool.submit(fetch_cert, host): host for host in hosts}
            units_fut = pool.submit(fetch_units)
            disk_fut = pool.submit(fetch_disk)
            pending_set = set(http_futs) | set(cert_futs) | {units_fut, disk_fut}
            done, pending = wait(pending_set, timeout=BUDGET_S)
            for fut in pending:
                fut.cancel()
            for fut, key in http_futs.items():
                if fut not in done:
                    http[key] = HttpResult(error="timeout")
                    continue
                try:
                    http[key] = fut.result()
                except Exception:
                    http[key] = HttpResult(error="unreachable")
            for key, url in urls.items():
                if not url:
                    http[key] = HttpResult(error="unconfigured")
            for fut, host in cert_futs.items():
                if fut not in done:
                    certs.append(CertResult(host=host, reachable=False, timed_out=True))
                    continue
                try:
                    certs.append(fut.result())
                except Exception:
                    certs.append(CertResult(host=host, reachable=False))
            if units_fut in done:
                try:
                    units = units_fut.result()
                except Exception:
                    units = UnitSnapshot(timed_out=True)
            else:
                units = UnitSnapshot(timed_out=True)
            if disk_fut in done:
                try:
                    disk = disk_fut.result()
                except Exception:
                    disk = DiskResult(error="failed")
            else:
                disk = DiskResult(error="timeout")
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
        return HealthSnapshot(
            http=http,
            units=units,
            certs=certs,
            disk=disk,
            optional_files=optional_markers(),
            location_backend=backend,
            push_enabled=push_on,
        )


def _load_payload(cfg: DashboardConfig, probes: object, cache: HealthCache, *, refresh: bool) -> dict:
    def loader() -> dict:
        try:
            snapshot = probes.snapshot(cfg)  # type: ignore[attr-defined]
            checks = report_from_snapshot(snapshot)
        except Exception:
            checks = unavailable_checks()
        return public_dict(checks, cached=False)

    return cache.get(loader, refresh=refresh)


def register_health_routes(app: FastAPI, cfg: DashboardConfig, probes: object, templates) -> None:
    cache = HealthCache(ttl_s=_cache_ttl(), min_refresh_s=15.0)
    app.state.health_cache = cache
    app.state.health_probes = probes or LiveHealthProbes()

    def parent_user(request: Request) -> str:
        user = username_from_headers(dict(request.headers))
        require_parent(user, cfg)
        return user  # type: ignore[return-value]

    def payload(refresh: str) -> dict:
        return _load_payload(cfg, app.state.health_probes, cache, refresh=refresh == "1")

    @app.get("/health", response_class=HTMLResponse)
    async def health_page(request: Request, user: str = Depends(parent_user), refresh: str = ""):
        data = payload(refresh)
        return templates.TemplateResponse(
            request,
            "health.html",
            {
                "user": user,
                "overall_label": _OVERALL_LABEL.get(data["overall"], _OVERALL_LABEL[STATUS_PROBLEM]),
                "checked_label": checked_label(data["checked_at"]),
                "cached": data["cached"],
                "checks": view_checks(data),
            },
        )

    @app.get("/api/health")
    async def health_api(request: Request, refresh: str = ""):
        auth = api_user(request, cfg)
        require_parent_user(auth, cfg)
        return JSONResponse(payload(refresh), headers={"Cache-Control": "no-store"})

