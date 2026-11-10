"""Local-only setup API for an unprovisioned TinyWeb box.

The process binds a private LAN address, checks the printed setup code, and
starts the existing one-box installer. When TWS_CONTROL_PLANE_URL is set it
asks the control plane to reserve the slug, issue a tunnel, and mark setup
complete, then runs scripts/cloudflared-apply.sh. Those gates become ready
only when that service says DNS was published and the edge certificate is
ready. A missing control plane, missing Cloudflare credentials, or an
unpublished handoff stays blocked. This module does not invent a hostname.
"""

from __future__ import annotations

import hmac
import ipaddress
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from tinyweb_setup.control_plane import (
    ControlPlaneClient,
    ControlPlaneError,
    PublishDecision,
    evaluate_handoff,
    handoff_proxies_jellyfin,
)
from tinyweb_setup.mdns import Announcer

SETUP_PORT = 4734
_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
_RESERVED_SLUGS = {
    "admin",
    "api",
    "autoconfig",
    "dns",
    "ftp",
    "imap",
    "localhost",
    "mail",
    "ns",
    "root",
    "setup",
    "smtp",
    "tinyweb",
    "wildcard",
    "www",
}


class SetupBindError(Exception):
    pass


class SetupRejected(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def is_loopback(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return isinstance(addr, ipaddress.IPv4Address) and addr.is_loopback


def is_lan_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if not isinstance(addr, ipaddress.IPv4Address) or addr.is_loopback:
        return False
    return bool(addr.is_private or addr.is_link_local)


def address_allowed(ip: str, *, allow_loopback: bool) -> bool:
    if is_lan_ip(ip):
        return True
    return bool(allow_loopback and is_loopback(ip))


def local_ipv4s() -> list[str]:
    try:
        out = subprocess.check_output(["ip", "-4", "-o", "addr", "show"], text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        return []
    found: list[str] = []
    for line in out.splitlines():
        parts = line.split()
        if "inet" not in parts:
            continue
        cidr = parts[parts.index("inet") + 1]
        found.append(cidr.split("/")[0])
    return found


def bind_addresses(explicit: list[str] | None, *, allow_loopback: bool) -> list[str]:
    if explicit:
        cleaned = [item.strip() for item in explicit if item.strip()]
        if not cleaned:
            raise SetupBindError("No address to listen on.")
        for ip in cleaned:
            if not address_allowed(ip, allow_loopback=allow_loopback):
                raise SetupBindError(
                    f"Refusing to listen on {ip}. TinyWeb setup stays on the home network."
                )
        return cleaned
    lan = [ip for ip in local_ipv4s() if is_lan_ip(ip)]
    if not lan:
        raise SetupBindError(
            "No private LAN address. TinyWeb setup will not listen on a public address."
        )
    return lan


def bash_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def password_env_key(username: str) -> str:
    return username.upper().replace(".", "_").replace("-", "_") + "_PASSWORD"


def extract_setup_code(raw: str) -> str:
    text = raw.strip()
    if not text:
        raise SetupRejected(400, "Enter the setup code from the card in the box.")
    if "://" in text or text.startswith("tinyweb:"):
        uri = urllib.parse.urlparse(text)
        if uri.query and "code=" in uri.query:
            raise SetupRejected(
                400,
                "That link puts the setup code in the wrong place. Scan the card again.",
            )
        host = (uri.hostname or "").lower()
        path = uri.path.rstrip("/") or "/"
        scheme = uri.scheme.lower()
        ok = (scheme == "tinyweb" and host == "setup") or (
            scheme == "https" and host == "tinyweb.win" and path == "/setup"
        )
        if not ok:
            raise SetupRejected(400, "That is not a TinyWeb setup code.")
        values = urllib.parse.parse_qs(uri.fragment, keep_blank_values=False).get("code") or []
        if not values or not values[0].strip():
            raise SetupRejected(400, "That setup link has no code.")
        token = values[0].strip()
    else:
        if any(mark in text for mark in ("/", "?", "#", " ")):
            raise SetupRejected(400, "That is not a TinyWeb setup code.")
        token = text
    if not _TOKEN_RE.fullmatch(token):
        raise SetupRejected(400, "That setup code does not look right. Scan the card again.")
    return token


def _clean_display_name(value: str, *, label: str) -> str:
    text = " ".join(value.split())
    if not text or len(text) > 60:
        raise SetupRejected(400, f"Enter a {label} using letters, such as Floyd.")
    if any(ord(ch) < 32 or ch in "=#&?/" for ch in text):
        raise SetupRejected(400, f"Enter a {label} using letters, such as Floyd.")
    if not any(ch.isalpha() for ch in text):
        raise SetupRejected(400, f"Enter a {label} using letters, such as Floyd.")
    return text


def slugify_family_name(family_name: str) -> str:
    cleaned = _clean_display_name(family_name, label="family name")
    out: list[str] = []
    prev_hyphen = False
    for ch in cleaned.lower():
        if "a" <= ch <= "z" or ch.isdigit():
            out.append(ch)
            prev_hyphen = False
        elif ch in " -'’" and out and not prev_hyphen:
            out.append("-")
            prev_hyphen = True
    slug = "".join(out).strip("-")
    if (
        len(slug) < 2
        or len(slug) > 32
        or "--" in slug
        or slug in _RESERVED_SLUGS
        or not re.fullmatch(r"[a-z][a-z0-9-]*[a-z0-9]", slug)
    ):
        raise SetupRejected(400, "Use a family name with letters, such as Floyd.")
    return slug


def username_from_parent_name(parent_name: str) -> str:
    cleaned = _clean_display_name(parent_name, label="name")
    first = cleaned.split()[0].lower()
    username = "".join(ch for ch in first if ch.isalnum())
    if not re.fullmatch(r"[a-z][a-z0-9]{1,31}", username):
        raise SetupRejected(400, "Use your first name with letters, such as William.")
    return username


def _atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        os.write(fd, data)
        os.fchmod(fd, mode)
        os.close(fd)
        fd = -1
        os.replace(tmp_name, path)
        os.chmod(path, mode)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def redact(text: str, secrets: list[str]) -> str:
    out = text
    for secret in secrets:
        if secret and len(secret) >= 4:
            out = out.replace(secret, "[redacted]")
    return out


class SetupConfig:
    def __init__(
        self,
        *,
        etc_dir: Path,
        state_dir: Path,
        code_file: Path,
        bind: list[str] | None,
        allow_loopback: bool,
        port: int,
        announce: bool,
        install_cmd: list[str] | None,
        repo_root: Path | None,
        base_domain: str,
        yunohost_marker: Path,
        gate_override: bool,
        gate_control_plane: str | None,
        gate_tunnel: str | None,
        control_plane_url: str | None = None,
        cloudflared_dest: Path | None = None,
        cert_polls: int = 0,
        cert_poll_seconds: float = 0,
        post_limit: int = 10,
        post_window_s: float = 600,
    ) -> None:
        self.etc_dir = etc_dir
        self.state_dir = state_dir
        self.code_file = code_file
        self.bind = bind
        self.allow_loopback = allow_loopback
        self.port = port
        self.announce = announce
        self.install_cmd = install_cmd
        self.repo_root = repo_root
        self.base_domain = base_domain
        self.yunohost_marker = yunohost_marker
        self.gate_override = gate_override
        self.gate_control_plane = gate_control_plane
        self.gate_tunnel = gate_tunnel
        self.control_plane_url = control_plane_url.strip() if control_plane_url else None
        self.cloudflared_dest = cloudflared_dest
        self.cert_polls = cert_polls
        self.cert_poll_seconds = cert_poll_seconds
        self.post_limit = post_limit
        self.post_window_s = post_window_s

    @property
    def marker_file(self) -> Path:
        return self.etc_dir / "unboxing-complete"

    @property
    def state_file(self) -> Path:
        return self.state_dir / "setup-state.json"

    @property
    def env_file(self) -> Path:
        return self.etc_dir / "tinyweb.env"

    @property
    def secrets_env(self) -> Path:
        return self.etc_dir / "secrets" / "install.env"

    @property
    def consumed_file(self) -> Path:
        return self.etc_dir / "setup-code.consumed"

    @property
    def claim_token_file(self) -> Path:
        return self.etc_dir / "cloudflared" / "claim-token"

    @property
    def handoff_file(self) -> Path:
        return self.etc_dir / "cloudflared" / "handoff.json"

    def cloudflared_apply_script(self) -> Path:
        starts: list[Path] = []
        if self.repo_root is not None:
            starts.append(self.repo_root)
        starts.extend(Path(__file__).resolve().parents)
        for root in starts:
            for relative in (Path("scripts") / "cloudflared-apply.sh", Path("cloudflared-apply.sh")):
                candidate = root / relative
                if candidate.is_file():
                    return candidate
        raise SetupBindError("Could not find cloudflared-apply.sh")

    def install_script(self) -> tuple[Path, Path]:
        starts = []
        if self.repo_root is not None:
            starts.append(self.repo_root)
        here = Path(__file__).resolve()
        starts.extend(here.parents)
        for root in starts:
            git_script = root / "scripts" / "install-on-box.sh"
            flat_script = root / "install-on-box.sh"
            if git_script.is_file():
                return root, git_script
            if flat_script.is_file():
                return root, flat_script
        raise SetupBindError("Could not find install-on-box.sh")

    @classmethod
    def from_env(cls) -> SetupConfig:
        etc = Path(os.environ.get("TWS_ETC_DIR", "/etc/tinywebstack"))
        bind_raw = os.environ.get("TWS_SETUP_BIND", "").strip()
        bind = [part.strip() for part in bind_raw.split(",") if part.strip()] or None
        allow_loopback = bool(bind) and all(is_loopback(ip) for ip in bind or [])
        install_raw = os.environ.get("TWS_SETUP_INSTALL_CMD", "").strip()
        repo = os.environ.get("TWS_SETUP_REPO_ROOT", "").strip()
        plane = os.environ.get("TWS_CONTROL_PLANE_URL", "").strip()
        dest = os.environ.get("TWS_SETUP_CLOUDFLARED_DEST", "").strip()
        return cls(
            etc_dir=etc,
            state_dir=Path(os.environ.get("TWS_SETUP_STATE_DIR", "/var/lib/tinywebstack")),
            code_file=Path(os.environ.get("TWS_SETUP_CODE_FILE", str(etc / "setup-code"))),
            bind=bind,
            allow_loopback=allow_loopback,
            port=int(os.environ.get("TWS_SETUP_PORT", str(SETUP_PORT))),
            announce=os.environ.get("TWS_SETUP_ANNOUNCE", "1") != "0",
            install_cmd=shlex.split(install_raw) if install_raw else None,
            repo_root=Path(repo) if repo else None,
            base_domain=os.environ.get("TWS_SETUP_BASE_DOMAIN", "tinyweb.win"),
            yunohost_marker=Path(os.environ.get("TWS_YUNOHOST_INSTALLED_FILE", "/etc/yunohost/installed")),
            gate_override=os.environ.get("TWS_SETUP_ALLOW_GATE_OVERRIDE", "") == "1",
            gate_control_plane=os.environ.get("TWS_SETUP_GATE_CONTROL_PLANE") or None,
            gate_tunnel=os.environ.get("TWS_SETUP_GATE_TUNNEL") or None,
            control_plane_url=plane or None,
            cloudflared_dest=Path(dest) if dest else None,
            cert_polls=int(os.environ.get("TWS_SETUP_CERT_POLLS", "4")),
            cert_poll_seconds=float(os.environ.get("TWS_SETUP_CERT_POLL_SECONDS", "2")),
            post_limit=int(os.environ.get("TWS_SETUP_POST_LIMIT", "10")),
            post_window_s=float(os.environ.get("TWS_SETUP_POST_WINDOW_S", "600")),
        )


class SetupStore:
    def __init__(self, config: SetupConfig) -> None:
        self.config = config
        self.phase = "waiting"
        self.family_slug: str | None = None
        self.family_name: str | None = None
        self.domain: str | None = None
        self.parent_username: str | None = None
        self.parent_name: str | None = None
        self.error: str | None = None
        self.install_detail = ""
        self.install_exit: int | None = None
        self.gates: dict[str, str] = {}
        self.gate_details: dict[str, str] = {}
        self.enroll_origin: str | None = None
        self.ready_at: float | None = None
        self.logs: list[str] = []
        self._secrets: list[str] = []
        self._posts: dict[str, list[float]] = {}
        self._proc: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()
        self._load()

    def note(self, message: str) -> None:
        clean = redact(message, self._secrets)
        self.logs.append(clean)
        print(f"[tinyweb-setup] {clean}", file=sys.stderr)

    def should_not_listen(self) -> bool:
        if self.config.marker_file.is_file():
            return True
        if self.phase in {"waiting", "installing", "blocked", "failed"} and self._state_on_disk():
            return False
        if self.phase == "ready":
            return True
        if self.config.yunohost_marker.is_file() and self.phase == "waiting" and not self._state_on_disk():
            return True
        return False

    def _state_on_disk(self) -> bool:
        return self.config.state_file.is_file()

    def _load(self) -> None:
        path = self.config.state_file
        if not path.is_file():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if not isinstance(data, dict):
            return
        phase = data.get("phase")
        if phase not in {"waiting", "installing", "blocked", "failed", "ready"}:
            return
        self.phase = "failed" if phase == "installing" else phase
        if phase == "installing":
            self.error = "Setup was interrupted. You can try again with the same setup code."
        self.family_slug = data.get("family_slug")
        self.family_name = data.get("family_name")
        self.domain = data.get("domain")
        self.parent_username = data.get("parent_username")
        self.parent_name = data.get("parent_name")
        self.install_exit = data.get("install_exit")
        self.gates = data.get("gates") if isinstance(data.get("gates"), dict) else {}
        details = data.get("gate_details")
        self.gate_details = details if isinstance(details, dict) else {}
        self.enroll_origin = data.get("enroll_origin")
        if self.phase == "failed" and not self.error:
            self.error = data.get("error")

    def _persist(self) -> None:
        payload = {
            "phase": self.phase,
            "family_slug": self.family_slug,
            "family_name": self.family_name,
            "domain": self.domain,
            "parent_username": self.parent_username,
            "parent_name": self.parent_name,
            "install_exit": self.install_exit,
            "gates": self.gates,
            "gate_details": self.gate_details,
            "enroll_origin": self.enroll_origin,
            "error": self.error,
        }
        _atomic_write(
            self.config.state_file,
            (json.dumps(payload, indent=2) + "\n").encode("utf-8"),
            0o600,
        )

    def _remember_secret(self, secret: str) -> None:
        if secret and secret not in self._secrets:
            self._secrets.append(secret)

    def current_code(self) -> str | None:
        path = self.config.code_file
        if not path.is_file():
            return None
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            return None
        self._remember_secret(text)
        return text

    def public_status(self, error: str | None = None) -> dict[str, Any]:
        with self._lock:
            body = self._status_unlocked()
        if error:
            body["error"] = error
        return body

    def _status_unlocked(self) -> dict[str, Any]:
        shown_error = self.error
        return {
            "service": "tinyweb-setup",
            "version": 1,
            "provisioned": self.phase == "ready",
            "phase": self.phase,
            "code_required": self.current_code() is not None,
            "family_slug": self.family_slug,
            "family_name": self.family_name,
            "domain": self.domain,
            "parent_username": self.parent_username,
            "parent_name": self.parent_name,
            "enroll_origin": self.enroll_origin,
            "error": shown_error,
            "steps": self._steps(),
        }

    def _steps(self) -> list[dict[str, str]]:
        phase = self.phase
        domain = self.domain or "<family>.tinyweb.win"
        account = "done" if phase != "waiting" else "current"
        if phase == "installing":
            install = "current"
        elif phase in {"blocked", "ready"}:
            install = "done"
        elif phase == "failed":
            install = "failed"
        else:
            install = "pending"

        def gated(gate: str, blocked_detail: str, done_detail: str) -> tuple[str, str]:
            if gate == "ready":
                return "done", done_detail
            if phase == "blocked":
                return "blocked", blocked_detail
            return "pending", ""

        cp = self.gates.get("control_plane", "missing")
        certificate = self.gates.get("certificate", cp)
        tunnel = self.gates.get("tunnel", "missing")
        name_state, name_detail = gated(
            cp,
            self.gate_details.get("name")
            or f"TinyWeb will publish {domain}. That step is not running yet, so setup stops here.",
            f"{domain} is published.",
        )
        cert_state, cert_detail = gated(
            certificate,
            self.gate_details.get("certificate")
            or (
                f"TinyWeb will get a real Let's Encrypt certificate for {domain}. "
                "That step is not running yet, so setup stops here instead of showing a certificate warning."
            ),
            "Let's Encrypt certificate is in place.",
        )
        tunnel_state, tunnel_detail = gated(
            tunnel,
            self.gate_details.get("tunnel")
            or "TinyWeb will open its own path to the internet so you do not change the router. That step is not running yet.",
            "The internet path is open.",
        )
        if phase == "ready":
            ready_state, ready_detail = "done", "You can add everyone else from this phone."
        elif phase == "blocked":
            ready_state, ready_detail = "pending", "Setup is not finished."
        elif phase == "failed":
            ready_state, ready_detail = "failed", ""
        else:
            ready_state, ready_detail = "pending", ""
        return [
            {"id": "account", "label": "Name the family", "state": account, "detail": ""},
            {
                "id": "install",
                "label": "Install TinyWeb",
                "state": install,
                "detail": self.install_detail if phase == "installing" else "",
            },
            {"id": "name", "label": f"Reserve {domain}", "state": name_state, "detail": name_detail},
            {
                "id": "certificate",
                "label": "Get a real Let's Encrypt certificate",
                "state": cert_state,
                "detail": cert_detail,
            },
            {
                "id": "tunnel",
                "label": "Open a path to the internet",
                "state": tunnel_state,
                "detail": tunnel_detail,
            },
            {"id": "ready", "label": "Ready for the family", "state": ready_state, "detail": ready_detail},
        ]

    def _allow_post(self, peer: str) -> bool:
        now = time.monotonic()
        window = [stamp for stamp in self._posts.get(peer, []) if now - stamp < self.config.post_window_s]
        if len(window) >= self.config.post_limit:
            self._posts[peer] = window
            return False
        window.append(now)
        self._posts[peer] = window
        return True

    def submit(self, *, peer: str, code: str, family_name: str, parent_name: str, password: str) -> dict[str, Any]:
        with self._lock:
            if not self._allow_post(peer):
                raise SetupRejected(429, "Too many tries. Wait a few minutes and try again.")
            if self.phase == "ready":
                raise SetupRejected(409, "This TinyWeb is already set up.")
            expected = self.current_code()
            if expected is None:
                raise SetupRejected(
                    400,
                    "This TinyWeb has no setup code yet. The card in the box is printed with the image.",
                )
            token = extract_setup_code(code)
            self._remember_secret(token)
            if not hmac.compare_digest(expected, token):
                raise SetupRejected(401, "That setup code does not match this TinyWeb.")
            retry_publish = (
                self.phase == "blocked"
                and self.install_exit == 0
                and bool(self.config.control_plane_url)
            )
            if self.phase in {"installing", "blocked"} and not retry_publish:
                raise SetupRejected(409, "This TinyWeb is already being set up.")
            slug = slugify_family_name(family_name)
            username = username_from_parent_name(parent_name)
            display_family = _clean_display_name(family_name, label="family name")
            display_parent = _clean_display_name(parent_name, label="name")
            if len(password) < 8 or len(password) > 128 or any(ord(ch) < 32 for ch in password):
                raise SetupRejected(400, "Use at least 8 characters for the password.")
            self._remember_secret(password)
        if retry_publish:
            if self.config.control_plane_url:
                self._publish_and_record()
            return self.public_status()
        if self.config.control_plane_url:
            self._reserve_name(slug, token)
        with self._lock:
            if self.phase in {"installing", "ready"} or (
                self.phase == "blocked" and self.install_exit == 0
            ):
                raise SetupRejected(409, "This TinyWeb is already being set up.")
            self._write_env(slug, username, display_parent)
            self._write_password(username, password)
            self.family_slug = slug
            self.family_name = display_family
            self.domain = f"{slug}.{self.config.base_domain}"
            self.parent_username = username
            self.parent_name = display_parent
            self.phase = "installing"
            self.error = None
            self.install_exit = None
            self.install_detail = "Installing."
            self.gates = {}
            self.gate_details = {}
            self.enroll_origin = None
            self.ready_at = None
            self._persist()
            cmd = self._install_command(slug)
            self.note(f"starting install for {slug}")
        self._spawn(cmd)
        return self.public_status()

    def _install_command(self, slug: str) -> list[str]:
        if self.config.install_cmd:
            return [*self.config.install_cmd, slug]
        root, script = self.config.install_script()
        self.config.repo_root = root
        return ["bash", str(script), "--family", slug]

    def _write_env(self, slug: str, username: str, parent_name: str) -> None:
        lines = [
            f"TWS_DOMAIN={slug}",
            "TWS_MODE=production",
            "TWS_TLS_SINGLE_SAN_CERT=1",
            "TWS_TLS_EDGE_CERT=1",
            f"TWS_BASE_DOMAIN={self.config.base_domain}",
            f"TWS_FAMILY_USERS={username}",
            f"TWS_FAMILY_PARENTS={username}",
            "TWS_FAMILY_KIDS=",
            f"TWS_FAMILY_OWNER={username}",
            f"TWS_FAMILY_OWNER_FULLNAME={parent_name}",
            "TWS_SWAP=auto",
        ]
        _atomic_write(self.config.env_file, ("\n".join(lines) + "\n").encode("utf-8"), 0o644)

    def _write_password(self, username: str, password: str) -> None:
        key = password_env_key(username)
        path = self.config.secrets_env
        existing = ""
        if path.is_file():
            kept = []
            for line in path.read_text(encoding="utf-8").splitlines():
                if not line.startswith(f"{key}="):
                    kept.append(line)
            existing = "\n".join(kept).strip()
        body = (existing + "\n" if existing else "") + f"{key}={bash_single_quote(password)}\n"
        _atomic_write(path, body.encode("utf-8"), 0o600)

    def _spawn(self, cmd: list[str]) -> None:
        env = os.environ.copy()
        env.pop("DRY_RUN", None)
        env["TWS_ETC_DIR"] = str(self.config.etc_dir)
        env["TWS_SETUP_FAMILY_SLUG"] = self.family_slug or ""
        for key in list(env):
            if key.endswith("_PASSWORD") or key in {
                "TWS_SETUP_CODE",
                "SETUP_CODE",
                "TWS_CONTROL_PLANE_OPERATOR_TOKEN",
            }:
                env.pop(key, None)
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=str(self.config.repo_root) if self.config.repo_root else None,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except OSError:
            with self._lock:
                self.phase = "failed"
                self.error = "TinyWeb could not finish installing. It is still on your home network. You can try again with the same setup code."
                self._persist()
            return
        with self._lock:
            self._proc = proc
        threading.Thread(target=self._drain, args=(proc,), name="tinyweb-setup-install", daemon=True).start()

    def _drain(self, proc: subprocess.Popen[str]) -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            clean = redact(line.rstrip("\n"), self._secrets)
            title = _step_title(clean)
            with self._lock:
                if title and self.phase == "installing":
                    self.install_detail = title
            if title:
                self.note(title)
        code = proc.wait()
        self._finish(code)

    def _finish(self, code: int) -> None:
        with self._lock:
            self.install_exit = code
            if code != 0:
                self.phase = "failed"
                self.install_detail = ""
                self.error = (
                    "TinyWeb could not finish installing. It is still on your home network. "
                    "You can try again with the same setup code."
                )
                self._persist()
                self.note(f"install failed ({code})")
                return
            use_plane = bool(self.config.control_plane_url)
        if use_plane:
            try:
                self._publish_and_record()
            except Exception:
                with self._lock:
                    if self.phase != "ready":
                        self.phase = "blocked"
                        self.enroll_origin = None
                        self.error = (
                            "TinyWeb could not publish the family name. No public name was published."
                        )
                        self._persist()
                self.note("setup publish failed")
            return
        with self._lock:
            self._apply_local_gates()

    def _apply_local_gates(self) -> None:
        control = self._resolve_gate("control_plane", self.config.gate_control_plane)
        tunnel = self._resolve_gate("tunnel", self.config.gate_tunnel)
        self.gates = {"control_plane": control, "tunnel": tunnel}
        self.gate_details = {}
        if control == "ready" and tunnel == "ready":
            self._mark_ready()
        else:
            self.phase = "blocked"
            self.enroll_origin = None
            self.error = None
            self.note("setup blocked until name, certificate, and tunnel gates are ready")
        self._persist()

    def _mark_ready(self) -> None:
        self.phase = "ready"
        self.error = None
        self.enroll_origin = f"https://{self.family_slug}.{self.config.base_domain}"
        self._consume_code()
        _atomic_write(self.config.marker_file, b"ready\n", 0o644)
        self.ready_at = time.monotonic()
        self.note(f"setup ready for {self.domain}")

    def _reserve_name(self, slug: str, setup_code: str) -> None:
        client = ControlPlaneClient(self.config.control_plane_url or "")
        try:
            client.check_slug(slug)
            claimed = client.claim(setup_code, slug)
        except ControlPlaneError as exc:
            raise _rejected(exc) from None
        token = str(claimed.get("claim_token") or "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{22,256}", token):
            raise SetupRejected(
                502,
                "TinyWeb could not reserve the family name. No public name was published.",
            )
        with self._lock:
            self._remember_secret(token)
        _atomic_write(self.config.claim_token_file, (token + "\n").encode("utf-8"), 0o600)
        self.note(f"reserved {slug} with the control plane")

    def _read_claim_token(self) -> str | None:
        path = self.config.claim_token_file
        if not path.is_file():
            return None
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            return None
        with self._lock:
            self._remember_secret(text)
        return text

    def _publish_and_record(self) -> None:
        with self._lock:
            if self.phase == "installing":
                self.install_detail = "Publishing the family name."
        decision, details, error = self._publish_once()
        polls = 0
        while (
            decision.reason == "certificate_pending"
            and polls < self.config.cert_polls
            and self.config.cert_poll_seconds > 0
        ):
            polls += 1
            time.sleep(self.config.cert_poll_seconds)
            decision, details, error = self._publish_once()
        self._record_publish(decision, details, error)

    def _publish_once(self) -> tuple[PublishDecision, dict[str, str], str | None]:
        client = ControlPlaneClient(self.config.control_plane_url or "")
        slug = self.family_slug or ""
        try:
            client.check_slug(slug)
        except ControlPlaneError as exc:
            return _stopped(exc, self.domain)
        token = self._read_claim_token()
        if not token:
            with self._lock:
                setup_code = self.current_code()
            if not setup_code:
                decision = PublishDecision(False, False, False, False, "missing")
                return decision, _blocked_details(decision, self.domain), (
                    "This TinyWeb has no setup code yet."
                )
            try:
                claimed = client.claim(setup_code, slug)
            except ControlPlaneError as exc:
                return _stopped(exc, self.domain)
            token = str(claimed.get("claim_token") or "")
            if not re.fullmatch(r"[A-Za-z0-9_-]{22,256}", token):
                decision = PublishDecision(False, False, False, False, "missing")
                return decision, _blocked_details(decision, self.domain), (
                    "TinyWeb could not reserve the family name. No public name was published."
                )
            with self._lock:
                self._remember_secret(token)
            _atomic_write(self.config.claim_token_file, (token + "\n").encode("utf-8"), 0o600)
        try:
            handoff = client.issue_tunnel(token, jellyfin=False)
        except ControlPlaneError as exc:
            return _stopped(exc, self.domain)
        tunnel = handoff.get("tunnel")
        tunnel_token = str(tunnel.get("token") or "") if isinstance(tunnel, dict) else ""
        with self._lock:
            self._remember_secret(token)
            if tunnel_token:
                self._remember_secret(tunnel_token)
        if handoff_proxies_jellyfin(handoff):
            decision = evaluate_handoff(handoff, None)
            return decision, _blocked_details(decision, self.domain), (
                "TinyWeb will not put Jellyfin on the internet path. No tunnel was started."
            )
        _atomic_write(
            self.config.handoff_file,
            (json.dumps(handoff) + "\n").encode("utf-8"),
            0o600,
        )
        apply_exit = self._run_apply()
        decision = evaluate_handoff(handoff, apply_exit)
        if decision.complete:
            try:
                client.complete(token)
            except ControlPlaneError as exc:
                failed = PublishDecision(
                    decision.name_ready,
                    decision.certificate_ready,
                    decision.tunnel_ready,
                    False,
                    "complete_failed",
                )
                return failed, _blocked_details(failed, self.domain), _parent_message(exc)
        return decision, _blocked_details(decision, self.domain), None

    def _run_apply(self) -> int:
        try:
            script = self.config.cloudflared_apply_script()
        except SetupBindError:
            self.note("cloudflared-apply.sh is missing")
            return 1
        cmd = ["bash", str(script), "--credentials", str(self.config.handoff_file)]
        if self.config.cloudflared_dest is not None:
            cmd.extend(["--dest-dir", str(self.config.cloudflared_dest)])
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired):
            self.note("cloudflared-apply failed to run")
            return 1
        combined = redact((proc.stdout or "") + "\n" + (proc.stderr or ""), self._secrets)
        self.note(f"cloudflared-apply exited {proc.returncode}")
        if proc.returncode != 0:
            tail = [line for line in combined.splitlines() if line.strip()]
            self.note((tail[-1] if tail else "cloudflared-apply refused the handoff")[:300])
        return proc.returncode

    def _record_publish(
        self,
        decision: PublishDecision,
        details: dict[str, str],
        error: str | None,
    ) -> None:
        with self._lock:
            self.gates = {
                "control_plane": "ready" if decision.name_ready else "missing",
                "certificate": "ready" if decision.certificate_ready else "missing",
                "tunnel": "ready" if decision.tunnel_ready else "missing",
            }
            self.gate_details = details
            self.install_detail = ""
            if decision.complete:
                self._mark_ready()
            else:
                self.phase = "blocked"
                self.enroll_origin = None
                self.error = error
                self.note("setup blocked until the control plane publishes the name, certificate, and tunnel")
            self._persist()

    def _resolve_gate(self, name: str, forced: str | None) -> str:
        if self.config.gate_override and forced in {"ready", "missing"}:
            return forced or "missing"
        hook = self.config.etc_dir / "setup-gates" / name
        if hook.is_file() and os.access(hook, os.X_OK):
            try:
                proc = subprocess.run([str(hook)], timeout=30, capture_output=True, check=False)
            except (OSError, subprocess.TimeoutExpired):
                return "missing"
            return "ready" if proc.returncode == 0 else "missing"
        return "missing"

    def _consume_code(self) -> None:
        path = self.config.code_file
        if path.is_file():
            path.unlink()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        _atomic_write(self.config.consumed_file, f"consumed {stamp}\n".encode("utf-8"), 0o600)


def _parent_message(exc: ControlPlaneError) -> str:
    messages = {
        "unknown_setup_code": "That setup code was not recognized. Scan the card in the box again.",
        "slug_taken": "That family name is already in use. Try a different name.",
        "slug_already_reserved": "This TinyWeb is already reserving a different family name.",
        "setup_already_complete": "This TinyWeb is already set up.",
        "invalid_slug": "Use a family name with letters, such as Floyd.",
        "reserved_slug": "Use a family name with letters, such as Floyd.",
        "cloudflare_not_configured": (
            "TinyWeb's service is missing the credentials it needs to publish the family name. "
            "No public name was published."
        ),
        "unreachable": (
            "TinyWeb could not reach its service. The box is still on your home network. "
            "You can try again with the same setup code."
        ),
        "secret_in_query": "TinyWeb refused to send the setup code in a web address.",
    }
    return messages.get(
        exc.code,
        "TinyWeb could not publish the family name. No public name was published.",
    )


def _rejected(exc: ControlPlaneError) -> SetupRejected:
    if exc.code == "unknown_setup_code":
        status = 401
    elif exc.code in {"slug_taken", "slug_already_reserved", "setup_already_complete"}:
        status = 409
    elif exc.code in {"invalid_slug", "reserved_slug"}:
        status = 400
    elif exc.code == "unreachable":
        status = 503
    else:
        status = 503
    return SetupRejected(status, _parent_message(exc))


def _blocked_details(decision: PublishDecision, domain: str | None) -> dict[str, str]:
    name = domain or "the family name"
    if decision.reason == "jellyfin":
        return {
            "name": f"TinyWeb has not published {name}. Jellyfin is not part of that path.",
            "certificate": (
                f"TinyWeb will get a real Let's Encrypt certificate for {name}. "
                "Setup stops here instead of showing a certificate warning."
            ),
            "tunnel": "TinyWeb did not start a tunnel. Jellyfin stays off the internet path.",
        }
    if not decision.name_ready:
        return {
            "name": f"TinyWeb has not published {name}. No public name was published, so setup stops here.",
            "certificate": (
                f"TinyWeb will get a real Let's Encrypt certificate for {name}. "
                "That certificate is not ready, so setup stops here instead of showing a certificate warning."
            ),
            "tunnel": "TinyWeb did not start a tunnel. The control plane has not published the name.",
        }
    return {
        "name": f"{name} is published.",
        "certificate": (
            f"TinyWeb does not have a real Let's Encrypt certificate for {name} yet, "
            "so setup stops here instead of showing a certificate warning."
        ),
        "tunnel": "TinyWeb could not open its path to the internet, so setup stops here.",
    }


def _stopped(
    exc: ControlPlaneError,
    domain: str | None,
) -> tuple[PublishDecision, dict[str, str], str]:
    decision = PublishDecision(False, False, False, False, exc.code or "unreachable")
    return decision, _blocked_details(decision, domain), _parent_message(exc)


def _step_title(line: str) -> str | None:
    if "=== Step" not in line or "complete" in line:
        return None
    title = line.split(":", 1)[-1].strip(" =")
    if not title or "password" in title.lower() or "secret" in title.lower():
        return None
    return title


class SetupHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], store: SetupStore) -> None:
        self.store = store
        super().__init__(server_address, SetupHandler)


class SetupHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: SetupHTTPServer

    def log_message(self, fmt: str, *args: Any) -> None:
        try:
            message = fmt % args
        except TypeError:
            message = "request"
        path = message.split(" ", 1)[-1] if message else ""
        if "code=" in path or "password" in path.lower():
            message = "request"
        self.server.store.note(message.split("?")[0])

    def handle_error(self, request: Any, client_address: Any) -> None:
        self.server.store.note("setup request failed")

    def _peer_ok(self) -> bool:
        peer = self.client_address[0]
        return address_allowed(peer, allow_loopback=self.server.store.config.allow_loopback)

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _path(self) -> str:
        return urllib.parse.urlparse(self.path).path

    def do_GET(self) -> None:  # noqa: N802
        if not self._peer_ok():
            self._send(
                403,
                self.server.store.public_status(
                    error="TinyWeb setup is only available on the home network."
                ),
            )
            return
        if self._path() != "/v1/setup/status":
            self._send(404, self.server.store.public_status(error="Not found."))
            return
        self._send(200, self.server.store.public_status())

    def do_POST(self) -> None:  # noqa: N802
        if not self._peer_ok():
            self._send(
                403,
                self.server.store.public_status(
                    error="TinyWeb setup is only available on the home network."
                ),
            )
            return
        if self._path() != "/v1/setup":
            self._send(404, self.server.store.public_status(error="Not found."))
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > 8192:
            self._send(400, self.server.store.public_status(error="TinyWeb could not read that setup request."))
            return
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            self._send(400, self.server.store.public_status(error="TinyWeb could not read that setup request."))
            return
        if not isinstance(data, dict):
            self._send(400, self.server.store.public_status(error="TinyWeb could not read that setup request."))
            return
        try:
            status = self.server.store.submit(
                peer=self.client_address[0],
                code=_require_str(data, "code"),
                family_name=_require_str(data, "family_name"),
                parent_name=_require_str(data, "parent_name"),
                password=_require_str(data, "password"),
            )
        except SetupRejected as exc:
            self._send(exc.status, self.server.store.public_status(error=exc.message))
            return
        self._send(200, status)


def _require_str(data: dict[str, Any], key: str) -> str:
    value = data.get(key, "")
    if not isinstance(value, str):
        raise SetupRejected(400, "TinyWeb could not read that setup request.")
    return value


def serve(store: SetupStore) -> list[SetupHTTPServer]:
    addresses = bind_addresses(store.config.bind, allow_loopback=store.config.allow_loopback)
    servers: list[SetupHTTPServer] = []
    for ip in addresses:
        httpd = SetupHTTPServer((ip, store.config.port), store)
        servers.append(httpd)
        threading.Thread(target=httpd.serve_forever, name=f"tinyweb-setup-{ip}", daemon=True).start()
    if store.config.announce and servers:
        bound_ip, bound_port = servers[0].server_address[:2]
        announcer = Announcer(int(bound_port), str(bound_ip))
        announcer.start()
        store_announcer(store, announcer)
    return servers


_announcers: dict[int, Announcer] = {}


def store_announcer(store: SetupStore, announcer: Announcer) -> None:
    _announcers[id(store)] = announcer


def main(argv: list[str] | None = None) -> int:
    del argv
    config = SetupConfig.from_env()
    store = SetupStore(config)
    if store.should_not_listen():
        store.note("TinyWeb is already set up. The setup service will not listen.")
        return 0
    try:
        servers = serve(store)
    except SetupBindError as exc:
        store.note(str(exc))
        return 1
    store.note("listening for setup on the home network")
    try:
        while True:
            if store.phase == "ready" and store.ready_at is not None:
                if time.monotonic() - store.ready_at >= 120:
                    break
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    announcer = _announcers.get(id(store))
    if announcer is not None:
        announcer.stop()
    for httpd in servers:
        httpd.shutdown()
        httpd.server_close()
    return 0
