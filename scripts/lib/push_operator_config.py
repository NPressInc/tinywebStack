#!/usr/bin/env python3
"""Load TinyWeb-operated APNs and FCM credentials for Sygnal.

Every family box uses this path by default. Parents do not upload a key file.
The same operator secrets (environment or /etc/tinywebstack/secrets/push/) are
installed on each box by William or the control plane.

A lab/dev operator may set TWS_PUSH_CREDENTIAL_SOURCE=override to point at
their own files. That override is not an unboxing step.

This module never calls Apple or Google and never treats a missing key as a
successful delivery. It does not log secret values.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Sequence


SHARED_SOURCE = "tinyweb"
OVERRIDE_SOURCE = "override"

DEFAULT_BUNDLE_ID = "win.tinyweb.tinyweb"
DEFAULT_ANDROID_APP_ID = "win.tinyweb.tinyweb.android"
DEFAULT_ETC_DIR = "/etc/tinywebstack"

SHARED_APNS_NAME = "tinyweb-apns-authkey.p8"
SHARED_FCM_NAME = "tinyweb-fcm-service-account.json"
OPERATOR_ENV_NAME = "operator.env"
LEGACY_APNS_REL = Path("secrets/apns/AuthKey.p8")
LEGACY_FCM_REL = Path("secrets/fcm/service-account.json")

_SOURCE_ALIASES = {
    "": SHARED_SOURCE,
    "tinyweb": SHARED_SOURCE,
    "shared": SHARED_SOURCE,
    "operator": SHARED_SOURCE,
    "override": OVERRIDE_SOURCE,
    "lab": OVERRIDE_SOURCE,
    "dev": OVERRIDE_SOURCE,
}

_ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_APPLE_ID = re.compile(r"^[A-Za-z0-9]{10}$")
_APP_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_PROJECT_ID = re.compile(r"^[A-Za-z0-9-]{4,63}$")
_MAX_SECRET_BYTES = 256 * 1024

# Names reported when that credential is absent. File and base64 forms satisfy
# the same requirement; they are not a second, family-specific key.
APNS_MATERIAL = "TWS_APNS_KEY"
FCM_MATERIAL = "TWS_FCM_SERVICE_ACCOUNT_JSON"


class PushCredentialsError(Exception):
    """Operator push credentials are missing or unusable. Delivery is not configured."""

    def __init__(
        self,
        message: str,
        *,
        missing: Sequence[str] = (),
        invalid: Sequence[str] = (),
        source: str = SHARED_SOURCE,
    ) -> None:
        super().__init__(message)
        self.missing = list(missing)
        self.invalid = list(invalid)
        self.source = source


@dataclass(frozen=True)
class PushCredentials:
    source: str
    apns_pem: str
    apns_key_id: str
    apns_team_id: str
    apns_bundle_id: str
    apns_platform: str
    apns_keyfile: Path
    apns_write_pem: bool
    fcm_json_text: str
    fcm_project_id: str
    fcm_file: Path
    fcm_write_json: bool
    ios_app_id: str
    android_app_id: str
    legacy_ignored: bool


def normalize_source(raw: Optional[str]) -> str:
    key = (raw or "").strip().lower()
    if key not in _SOURCE_ALIASES:
        raise PushCredentialsError(
            "TWS_PUSH_CREDENTIAL_SOURCE must be tinyweb (default, shared TinyWeb "
            "APNs/FCM keys) or override (lab/dev operator keys only). "
            "Delivery is not configured.",
            invalid=["TWS_PUSH_CREDENTIAL_SOURCE"],
        )
    return _SOURCE_ALIASES[key]


def shared_push_dir(etc_dir: Path) -> Path:
    return etc_dir / "secrets" / "push"


def default_apns_keyfile(etc_dir: Path) -> Path:
    return shared_push_dir(etc_dir) / SHARED_APNS_NAME


def default_fcm_file(etc_dir: Path) -> Path:
    return shared_push_dir(etc_dir) / SHARED_FCM_NAME


def operator_env_path(etc_dir: Path) -> Path:
    return shared_push_dir(etc_dir) / OPERATOR_ENV_NAME


def legacy_apns_path(etc_dir: Path) -> Path:
    return etc_dir / LEGACY_APNS_REL


def legacy_fcm_path(etc_dir: Path) -> Path:
    return etc_dir / LEGACY_FCM_REL


def parse_operator_env(text: str) -> dict[str, str]:
    """Parse KEY=value lines. Does not expand shell or return secret values in errors."""
    parsed: dict[str, str] = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise PushCredentialsError(
                f"operator.env line {lineno} is not KEY=value. Delivery is not configured.",
                invalid=["operator.env"],
            )
        key, val = line.split("=", 1)
        key = key.strip()
        if not _ENV_KEY.match(key):
            raise PushCredentialsError(
                f"operator.env line {lineno} has an invalid key. Delivery is not configured.",
                invalid=["operator.env"],
            )
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        parsed[key] = val
    return parsed


def _reject_world_readable(path: Path, label: str) -> None:
    mode = path.stat().st_mode
    if mode & stat.S_IROTH:
        raise PushCredentialsError(
            f"{label} at {path} is world-readable; chmod 600 before using it. "
            "Delivery is not configured.",
            invalid=[label],
        )


def merged_env(environ: Mapping[str, str], etc_dir: Path) -> dict[str, str]:
    """Process environment wins. operator.env fills only blank keys."""
    merged = {k: v for k, v in environ.items()}
    path = operator_env_path(etc_dir)
    if not path.is_file():
        return merged
    _reject_world_readable(path, "operator.env")
    size = path.stat().st_size
    if size > _MAX_SECRET_BYTES:
        raise PushCredentialsError(
            "operator.env is unexpectedly large. Delivery is not configured.",
            invalid=["operator.env"],
        )
    file_env = parse_operator_env(path.read_text(encoding="utf-8"))
    for key, val in file_env.items():
        current = merged.get(key, "")
        if not str(current).strip():
            merged[key] = val
    return merged


def _blank(env: Mapping[str, str], name: str) -> str:
    return str(env.get(name, "")).strip()


def _checked_path(path: Path, label: str) -> Path:
    text = str(path)
    if not text or "\n" in text or "\r" in text or "\x00" in text:
        raise PushCredentialsError(
            f"{label} is not a usable file path. Delivery is not configured.",
            invalid=[label],
        )
    return path


def _read_secret_file(path: Path, label: str) -> str:
    path = _checked_path(path, label)
    if not path.is_file():
        raise PushCredentialsError(
            f"{label} does not exist at {path}. Delivery is not configured.",
            missing=[label],
        )
    size = path.stat().st_size
    if size == 0 or size > _MAX_SECRET_BYTES:
        raise PushCredentialsError(
            f"{label} at {path} is empty or unexpectedly large. Delivery is not configured.",
            invalid=[label],
        )
    return path.read_text(encoding="utf-8")


def _decode_b64(value: str, label: str) -> str:
    try:
        raw = base64.b64decode(value.strip(), validate=True)
        text = raw.decode("utf-8")
    except (ValueError, UnicodeError):
        raise PushCredentialsError(
            f"{label} is not valid base64 text. Delivery is not configured.",
            invalid=[label],
        ) from None
    if not text.strip():
        raise PushCredentialsError(
            f"{label} decoded to an empty value. Delivery is not configured.",
            invalid=[label],
        )
    return text


def _is_pem_private_key(text: str) -> bool:
    compact = text.strip()
    end_ok = "-----END PRIVATE KEY-----" in compact or "-----END EC PRIVATE KEY-----" in compact
    begin_ok = (
        "-----BEGIN PRIVATE KEY-----" in compact or "-----BEGIN EC PRIVATE KEY-----" in compact
    )
    return begin_ok and end_ok


def _require_pem(text: str, label: str) -> str:
    if not _is_pem_private_key(text):
        raise PushCredentialsError(
            f"{label} is not a PEM private key (APNs AuthKey .p8). "
            "Delivery is not configured.",
            invalid=[label],
        )
    return text.strip() + "\n"


def _load_fcm_document(text: str, label: str, project_override: str) -> tuple[str, str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        raise PushCredentialsError(
            f"{label} is not a JSON service account. Delivery is not configured.",
            invalid=[label],
        ) from None
    if not isinstance(data, dict):
        raise PushCredentialsError(
            f"{label} must be a JSON object. Delivery is not configured.",
            invalid=[label],
        )
    if data.get("type") != "service_account":
        raise PushCredentialsError(
            f"{label} must be a Firebase service account (type=service_account). "
            "Delivery is not configured.",
            invalid=[label],
        )
    project_id = str(data.get("project_id", "")).strip()
    private_key = data.get("private_key")
    client_email = str(data.get("client_email", "")).strip()
    if not isinstance(private_key, str) or not _is_pem_private_key(private_key):
        raise PushCredentialsError(
            f"{label} is missing a PEM private_key. Delivery is not configured.",
            invalid=[label],
        )
    if "@" not in client_email:
        raise PushCredentialsError(
            f"{label} is missing client_email. Delivery is not configured.",
            invalid=[label],
        )
    if not _PROJECT_ID.match(project_id):
        raise PushCredentialsError(
            f"{label} has an unusable project_id. Delivery is not configured.",
            invalid=[label],
        )
    if project_override and project_override != project_id:
        raise PushCredentialsError(
            "TWS_FCM_PROJECT_ID does not match project_id in the Firebase service "
            "account. Delivery is not configured.",
            invalid=["TWS_FCM_PROJECT_ID"],
        )
    # Re-serialize so the on-disk file is the document we validated, not a log.
    canonical = json.dumps(data, indent=2) + "\n"
    return canonical, project_id


def _legacy_present(env: Mapping[str, str], etc_dir: Path) -> bool:
    if _blank(env, "TWS_APNS_KEY_PATH"):
        return True
    return legacy_apns_path(etc_dir).is_file()


def _resolve_apns_material(
    env: Mapping[str, str], etc_dir: Path, source: str
) -> tuple[str, Path, bool]:
    """Return (pem, keyfile Sygnal should read, whether we must write the pem)."""
    raw = _blank(env, "TWS_APNS_KEY")
    if raw:
        dest = default_apns_keyfile(etc_dir)
        return _require_pem(raw, "TWS_APNS_KEY"), dest, True
    b64 = _blank(env, "TWS_APNS_KEY_B64")
    if b64:
        dest = default_apns_keyfile(etc_dir)
        return _require_pem(_decode_b64(b64, "TWS_APNS_KEY_B64"), "TWS_APNS_KEY_B64"), dest, True
    explicit = _blank(env, "TWS_APNS_KEY_FILE")
    if explicit:
        path = Path(explicit)
        return _require_pem(_read_secret_file(path, "TWS_APNS_KEY_FILE"), "TWS_APNS_KEY_FILE"), path, False
    if source == OVERRIDE_SOURCE:
        legacy_env = _blank(env, "TWS_APNS_KEY_PATH")
        path = Path(legacy_env) if legacy_env else legacy_apns_path(etc_dir)
        if path.is_file() or legacy_env:
            return (
                _require_pem(_read_secret_file(path, "TWS_APNS_KEY_PATH"), "TWS_APNS_KEY_PATH"),
                path,
                False,
            )
    else:
        shared = default_apns_keyfile(etc_dir)
        if shared.is_file():
            return (
                _require_pem(_read_secret_file(shared, "TWS_APNS_KEY"), "TWS_APNS_KEY"),
                shared,
                False,
            )
    raise PushCredentialsError(
        "missing",
        missing=[APNS_MATERIAL],
        source=source,
    )


def _resolve_fcm_material(
    env: Mapping[str, str], etc_dir: Path, source: str
) -> tuple[str, str, Path, bool]:
    project_override = _blank(env, "TWS_FCM_PROJECT_ID")
    raw = _blank(env, "TWS_FCM_SERVICE_ACCOUNT_JSON")
    if raw:
        text, project_id = _load_fcm_document(raw, "TWS_FCM_SERVICE_ACCOUNT_JSON", project_override)
        return text, project_id, default_fcm_file(etc_dir), True
    b64 = _blank(env, "TWS_FCM_SERVICE_ACCOUNT_JSON_B64")
    if b64:
        decoded = _decode_b64(b64, "TWS_FCM_SERVICE_ACCOUNT_JSON_B64")
        text, project_id = _load_fcm_document(
            decoded, "TWS_FCM_SERVICE_ACCOUNT_JSON_B64", project_override
        )
        return text, project_id, default_fcm_file(etc_dir), True
    explicit = _blank(env, "TWS_FCM_SERVICE_ACCOUNT_FILE")
    if explicit:
        path = Path(explicit)
        text, project_id = _load_fcm_document(
            _read_secret_file(path, "TWS_FCM_SERVICE_ACCOUNT_FILE"),
            "TWS_FCM_SERVICE_ACCOUNT_FILE",
            project_override,
        )
        return text, project_id, path, False
    if source == OVERRIDE_SOURCE:
        legacy = legacy_fcm_path(etc_dir)
        if legacy.is_file():
            text, project_id = _load_fcm_document(
                _read_secret_file(legacy, "TWS_FCM_SERVICE_ACCOUNT_FILE"),
                "TWS_FCM_SERVICE_ACCOUNT_FILE",
                project_override,
            )
            return text, project_id, legacy, False
    else:
        shared = default_fcm_file(etc_dir)
        if shared.is_file():
            text, project_id = _load_fcm_document(
                _read_secret_file(shared, "TWS_FCM_SERVICE_ACCOUNT_JSON"),
                "TWS_FCM_SERVICE_ACCOUNT_JSON",
                project_override,
            )
            return text, project_id, shared, False
    raise PushCredentialsError(
        "missing",
        missing=[FCM_MATERIAL],
        source=source,
    )


def _platform(env: Mapping[str, str], source: str) -> str:
    raw = _blank(env, "TWS_APNS_ENV")
    if not raw:
        return "sandbox" if source == OVERRIDE_SOURCE else "production"
    if raw not in ("production", "sandbox"):
        raise PushCredentialsError(
            "TWS_APNS_ENV must be production or sandbox. Delivery is not configured.",
            invalid=["TWS_APNS_ENV"],
            source=source,
        )
    return raw


def load_push_credentials(env: Mapping[str, str], etc_dir: Path) -> PushCredentials:
    """Load shared TinyWeb credentials, or the lab/dev override.

    Raises PushCredentialsError when a required secret is missing or unusable.
    The exception text names variables and paths only.
    """
    etc_dir = Path(etc_dir)
    try:
        source = normalize_source(env.get("TWS_PUSH_CREDENTIAL_SOURCE"))
    except PushCredentialsError:
        raise
    env = merged_env(env, etc_dir)
    # Re-read source after operator.env merge. Process env already won inside merged_env
    # when it was non-blank, so an explicit process value is preserved.
    source = normalize_source(env.get("TWS_PUSH_CREDENTIAL_SOURCE"))

    missing: list[str] = []
    apns: Optional[tuple[str, Path, bool]] = None
    fcm: Optional[tuple[str, str, Path, bool]] = None
    try:
        apns = _resolve_apns_material(env, etc_dir, source)
    except PushCredentialsError as exc:
        if exc.missing == [APNS_MATERIAL] and exc.args == ("missing",):
            missing.append(APNS_MATERIAL)
        else:
            raise
    try:
        fcm = _resolve_fcm_material(env, etc_dir, source)
    except PushCredentialsError as exc:
        if exc.missing == [FCM_MATERIAL] and exc.args == ("missing",):
            missing.append(FCM_MATERIAL)
        else:
            raise

    key_id = _blank(env, "TWS_APNS_KEY_ID")
    team_id = _blank(env, "TWS_APNS_TEAM_ID")
    if not key_id:
        missing.append("TWS_APNS_KEY_ID")
    elif not _APPLE_ID.match(key_id):
        raise PushCredentialsError(
            "TWS_APNS_KEY_ID must be the 10-character Apple key id. "
            "Delivery is not configured.",
            invalid=["TWS_APNS_KEY_ID"],
            source=source,
        )
    if not team_id:
        missing.append("TWS_APNS_TEAM_ID")
    elif not _APPLE_ID.match(team_id):
        raise PushCredentialsError(
            "TWS_APNS_TEAM_ID must be the 10-character Apple team id. "
            "Delivery is not configured.",
            invalid=["TWS_APNS_TEAM_ID"],
            source=source,
        )

    bundle = _blank(env, "TWS_APNS_BUNDLE_ID") or DEFAULT_BUNDLE_ID
    android = _blank(env, "TWS_ANDROID_APP_ID") or DEFAULT_ANDROID_APP_ID
    if not _APP_ID.match(bundle):
        raise PushCredentialsError(
            "TWS_APNS_BUNDLE_ID is not a usable app id. Delivery is not configured.",
            invalid=["TWS_APNS_BUNDLE_ID"],
            source=source,
        )
    if not _APP_ID.match(android):
        raise PushCredentialsError(
            "TWS_ANDROID_APP_ID is not a usable app id. Delivery is not configured.",
            invalid=["TWS_ANDROID_APP_ID"],
            source=source,
        )
    platform = _platform(env, source)

    if missing:
        raise _missing_error(env, etc_dir, source, missing)

    assert apns is not None and fcm is not None
    pem, keyfile, write_pem = apns
    fcm_text, project_id, fcm_file, write_json = fcm
    ios_app_id = f"{bundle}.ios"
    return PushCredentials(
        source=source,
        apns_pem=pem,
        apns_key_id=key_id,
        apns_team_id=team_id,
        apns_bundle_id=bundle,
        apns_platform=platform,
        apns_keyfile=keyfile,
        apns_write_pem=write_pem,
        fcm_json_text=fcm_text,
        fcm_project_id=project_id,
        fcm_file=fcm_file,
        fcm_write_json=write_json,
        ios_app_id=ios_app_id,
        android_app_id=android,
        legacy_ignored=source == SHARED_SOURCE and _legacy_present(env, etc_dir),
    )


def _missing_error(
    env: Mapping[str, str], etc_dir: Path, source: str, missing: Sequence[str]
) -> PushCredentialsError:
    names = ", ".join(missing)
    lines = [
        f"TinyWeb push operator credentials are missing (source={source}).",
        "Delivery is not configured.",
        f"Missing: {names}.",
    ]
    if source == SHARED_SOURCE:
        lines.append(
            "Provide TinyWeb-operated APNs and FCM secrets via the environment or "
            f"{shared_push_dir(etc_dir)} (see docs/PUSH.md)."
        )
        lines.append(
            "A parent-uploaded per-family key file is not used for v1 unboxing."
        )
        if _legacy_present(env, etc_dir):
            lines.append(
                f"Ignoring deprecated per-family key file ({legacy_apns_path(etc_dir)} "
                "or TWS_APNS_KEY_PATH). Lab/dev operators may set "
                "TWS_PUSH_CREDENTIAL_SOURCE=override."
            )
    else:
        lines.append(
            "Override mode still needs operator-supplied APNs and FCM credentials. "
            "It does not fall back to a successful delivery."
        )
    return PushCredentialsError(" ".join(lines), missing=list(missing), source=source)


def render_sygnal_yaml(creds: PushCredentials, port: int) -> str:
    if not 1 <= port <= 65535:
        raise PushCredentialsError(
            "TWS_SYGNAL_PORT is not a usable port. Delivery is not configured.",
            invalid=["TWS_SYGNAL_PORT"],
            source=creds.source,
        )
    keyfile = _yaml_scalar(str(creds.apns_keyfile))
    fcm_file = _yaml_scalar(str(creds.fcm_file))
    ios = _yaml_key(creds.ios_app_id)
    android = _yaml_key(creds.android_app_id)
    return f"""# Managed by tinywebStack configure-push-credentials.sh
# Credential source: {creds.source}. TinyWeb-operated APNs and FCM keys.
# Not a key file uploaded by a family during unboxing.
log:
  setup:
    version: 1
    formatters:
      precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: precise
    root:
      level: INFO
      handlers: [console]
http:
  bind_addresses: ['127.0.0.1']
  port: {port}
apps:
  {ios}:
    type: apns
    keyfile: {keyfile}
    key_id: {creds.apns_key_id}
    team_id: {creds.apns_team_id}
    topic: {creds.apns_bundle_id}
    platform: {creds.apns_platform}
    default_payload:
      aps:
        alert:
          title: TinyWeb
          body: New message
        mutable-content: 1
  {android}:
    type: gcm
    api_version: v1
    project_id: {creds.fcm_project_id}
    service_account_file: {fcm_file}
"""


def render_unconfigured_sygnal_yaml(port: int) -> str:
    if not 1 <= port <= 65535:
        port = 5000
    return f"""# Managed by tinywebStack configure-push-credentials.sh
# APNs/FCM operator credentials are missing. Sygnal delivery is refused.
log:
  setup:
    version: 1
    formatters:
      precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
    handlers:
      console:
        class: logging.StreamHandler
        formatter: precise
    root:
      level: INFO
      handlers: [console]
http:
  bind_addresses: ['127.0.0.1']
  port: {port}
apps: {{}}
"""


def status_document(
    *,
    source: str,
    configured: bool,
    missing: Sequence[str] = (),
    invalid: Sequence[str] = (),
    error: str = "",
    creds: Optional[PushCredentials] = None,
) -> dict:
    doc: dict = {
        "source": source,
        "configured": configured,
        "delivery": "sygnal" if configured else "refused",
        "missing": list(missing),
        "invalid": list(invalid),
    }
    if error:
        doc["error"] = error
    if creds is not None and configured:
        doc["apns"] = {
            "configured": True,
            "platform": creds.apns_platform,
            "keyfile": str(creds.apns_keyfile),
            "topic": creds.apns_bundle_id,
        }
        doc["fcm"] = {
            "configured": True,
            "project_id": creds.fcm_project_id,
            "service_account_file": str(creds.fcm_file),
        }
        doc["ios_app_id"] = creds.ios_app_id
        doc["android_app_id"] = creds.android_app_id
        doc["legacy_per_family_key_ignored"] = creds.legacy_ignored
    return doc


def _yaml_scalar(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:+-]+", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _yaml_key(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9._-]+", value):
        return value
    return _yaml_scalar(value)


def _write_file(path: Path, data: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data.encode("utf-8"))
        os.fsync(fd)
    except Exception:
        os.close(fd)
        tmp.unlink(missing_ok=True)
        raise
    os.close(fd)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    os.chmod(path, mode)


def _ensure_dirs(etc_dir: Path) -> None:
    secrets = etc_dir / "secrets"
    push = shared_push_dir(etc_dir)
    status_dir = etc_dir / "push"
    for directory, mode in ((secrets, 0o750), (push, 0o750), (status_dir, 0o755)):
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, mode)


def apply_push_config(
    env: Mapping[str, str],
    etc_dir: Path,
    *,
    sygnal_port: int = 5000,
    write_sygnal: bool = False,
) -> dict:
    """Validate credentials and write status. Write Sygnal config when asked.

    On failure, Sygnal config (if written) has an empty apps map. No key file
    is written unless the full credential set validated.
    """
    etc_dir = Path(etc_dir)
    _ensure_dirs(etc_dir)
    source = SHARED_SOURCE
    try:
        creds = load_push_credentials(env, etc_dir)
        source = creds.source
    except PushCredentialsError as exc:
        source = exc.source or source
        doc = status_document(
            source=source,
            configured=False,
            missing=exc.missing,
            invalid=exc.invalid,
            error=str(exc),
        )
        _write_file(etc_dir / "push" / "credential-status.json", json.dumps(doc, indent=2) + "\n", 0o644)
        if write_sygnal:
            _write_file(etc_dir / "sygnal.yaml", render_unconfigured_sygnal_yaml(sygnal_port), 0o640)
        raise
    if creds.apns_write_pem:
        _write_file(creds.apns_keyfile, creds.apns_pem, 0o640)
    if creds.fcm_write_json:
        _write_file(creds.fcm_file, creds.fcm_json_text, 0o640)
    doc = status_document(source=creds.source, configured=True, creds=creds)
    _write_file(etc_dir / "push" / "credential-status.json", json.dumps(doc, indent=2) + "\n", 0o644)
    if write_sygnal:
        _write_file(etc_dir / "sygnal.yaml", render_sygnal_yaml(creds, sygnal_port), 0o640)
    return doc


def _port_from_env(env: Mapping[str, str]) -> int:
    raw = str(env.get("TWS_SYGNAL_PORT", "5000")).strip() or "5000"
    try:
        port = int(raw)
    except ValueError:
        raise PushCredentialsError(
            "TWS_SYGNAL_PORT is not a number. Delivery is not configured.",
            invalid=["TWS_SYGNAL_PORT"],
        ) from None
    return port


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Configure TinyWeb-operated APNs/FCM credentials for Sygnal."
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("apply", "check"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--etc-dir", default=os.environ.get("TWS_ETC_DIR", DEFAULT_ETC_DIR))
        cmd.add_argument("--sygnal-port", type=int, default=None)
    args = parser.parse_args(list(argv) if argv is not None else None)
    etc_dir = Path(args.etc_dir)
    try:
        port = args.sygnal_port if args.sygnal_port is not None else _port_from_env(os.environ)
    except PushCredentialsError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if args.cmd == "check":
        try:
            creds = load_push_credentials(os.environ, etc_dir)
        except PushCredentialsError as exc:
            doc = status_document(
                source=exc.source,
                configured=False,
                missing=exc.missing,
                invalid=exc.invalid,
                error=str(exc),
            )
            print(json.dumps(doc))
            print(str(exc), file=sys.stderr)
            return 2
        print(json.dumps(status_document(source=creds.source, configured=True, creds=creds)))
        return 0
    try:
        doc = apply_push_config(
            os.environ,
            etc_dir,
            sygnal_port=port,
            write_sygnal=True if args.cmd == "apply" else False,
        )
    except PushCredentialsError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(
        f"TinyWeb push credentials configured source={doc['source']} delivery=sygnal",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
