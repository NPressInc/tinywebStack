#!/usr/bin/env python3
"""Mint one TinyWeb unit before the box ships.

William runs this on an already-imaged box. It asks the control plane for a
one-time setup code, writes that code where first boot expects it, enables the
setup service for the next boot, and prints the lid/sticker QR.

It does not choose the family name or the parent password, and it does not
print a Matrix recovery key. The token is not written to a log file. Stdout is
the print surface for the URL. The operator token is read from the environment,
never from the command line.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from tinyweb_setup.control_plane import (  # noqa: E402
    ControlPlaneClient,
    ControlPlaneError,
    code_is_strong,
)

_UNIT_NAME = "tinyweb-setupd.service"


def _die(message: str, code: int = 1) -> int:
    print(message, file=sys.stderr)
    return code


def _atomic_secret(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        os.write(fd, data)
        os.fchmod(fd, 0o600)
        os.close(fd)
        fd = -1
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def _urls_from_mint(payload: dict[str, object]) -> tuple[str, str, str]:
    code = payload.get("setup_code")
    https_url = payload.get("setup_url")
    app_url = payload.get("setup_app_url")
    if not isinstance(code, str) or not isinstance(https_url, str) or not isinstance(app_url, str):
        raise ControlPlaneError(
            "The control plane did not return a setup code. No setup code was written.",
            code="bad_response",
        )
    if not code_is_strong(code):
        raise ControlPlaneError(
            "The control plane returned a setup code that is too short. No setup code was written.",
            code="weak_code",
        )
    parsed = urllib.parse.urlparse(https_url)
    fragment = urllib.parse.parse_qs(parsed.fragment, keep_blank_values=False)
    app = urllib.parse.urlparse(app_url)
    app_fragment = urllib.parse.parse_qs(app.fragment, keep_blank_values=False)
    https_ok = (
        parsed.scheme == "https"
        and parsed.path.rstrip("/") == "/setup"
        and not parsed.query
        and fragment.get("code") == [code]
    )
    app_ok = (
        app.scheme == "tinyweb"
        and (app.hostname or "") == "setup"
        and not app.query
        and app_fragment.get("code") == [code]
    )
    if not https_ok or not app_ok:
        raise ControlPlaneError(
            "The control plane returned an unexpected setup URL. No setup code was written.",
            code="bad_url",
        )
    return code, https_url, app_url


def write_qr(path: Path, payload: str) -> None:
    """Write a printable SVG. The file is mode 600 because it contains the code."""
    import qrcode
    import qrcode.image.svg

    image = qrcode.make(payload, image_factory=qrcode.image.svg.SvgPathImage)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        os.close(fd)
        fd = -1
        image.save(tmp_name)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def _unit_source() -> Path:
    candidate = _HERE / _UNIT_NAME
    if candidate.is_file():
        return candidate
    raise ControlPlaneError(
        f"Could not find {_UNIT_NAME} next to pre-ship.py. No setup code was written.",
        code="missing_unit",
    )


def _unit_text(base_url: str) -> str:
    text = _unit_source().read_text(encoding="utf-8")
    line = f"Environment=TWS_CONTROL_PLANE_URL={base_url}"
    if re.search(r"^Environment=TWS_CONTROL_PLANE_URL=.*$", text, flags=re.M):
        return re.sub(r"^Environment=TWS_CONTROL_PLANE_URL=.*$", line, text, count=1, flags=re.M)
    return text.replace("[Service]\n", "[Service]\n" + line + "\n", 1)


def _stage_service(stage: Path, unit_text: str) -> str:
    systemd = stage / "systemd"
    systemd.mkdir(parents=True, exist_ok=True)
    dest = systemd / _UNIT_NAME
    dest.write_text(unit_text, encoding="utf-8")
    os.chmod(dest, 0o644)
    (systemd / "enabled").write_text(_UNIT_NAME + "\n", encoding="utf-8")
    os.chmod(systemd / "enabled", 0o644)
    return f"staged {_UNIT_NAME} in {systemd} (not started)"


def _enable_service(unit_text: str) -> str:
    if os.geteuid() != 0:
        raise ControlPlaneError(
            "pre-ship.py must run as root to enable the setup service. "
            "The setup code was written. The service was not enabled.",
            code="not_root",
        )
    dest = Path("/etc/systemd/system") / _UNIT_NAME
    dest.parent.mkdir(parents=True, exist_ok=True)
    _atomic_public(dest, unit_text.encode("utf-8"))
    if shutil.which("systemctl") is None:
        raise ControlPlaneError(
            "systemctl is not available. The setup code was written. The service was not enabled.",
            code="no_systemctl",
        )
    proc = subprocess.run(
        ["systemctl", "enable", _UNIT_NAME],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise ControlPlaneError(
            "systemctl enable failed. The setup code was written. The service was not enabled.",
            code="systemctl_failed",
        )
    return f"enabled {_UNIT_NAME} for the next boot (not started)"


def _atomic_public(path: Path, data: bytes) -> None:
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        os.write(fd, data)
        os.fchmod(fd, 0o644)
        os.close(fd)
        fd = -1
        os.replace(tmp_name, path)
        os.chmod(path, 0o644)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def _parse(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Mint a TinyWeb setup code, write it on this box, and print the lid QR. "
            "Does not set the family name or the parent password."
        )
    )
    parser.add_argument(
        "--url",
        default="",
        help="Control plane base URL. Defaults to TWS_CONTROL_PLANE_URL, then https://tinyweb.win.",
    )
    parser.add_argument(
        "--stage-dir",
        default="",
        help="Write the code, QR, and unit here instead of /etc and systemctl. For tests and a rehearsal.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Check that the operator token is set, then exit without calling the control plane.",
    )
    args = parser.parse_args(argv)
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse(list(sys.argv[1:] if argv is None else argv))
    token = os.environ.get("TWS_CONTROL_PLANE_OPERATOR_TOKEN", "").strip()
    if not token:
        return _die(
            "Set TWS_CONTROL_PLANE_OPERATOR_TOKEN. No setup code was written.",
            2,
        )
    base = (args.url or os.environ.get("TWS_CONTROL_PLANE_URL", "") or "https://tinyweb.win").strip()
    try:
        normalize_target = ControlPlaneClient(base).base_url
    except ControlPlaneError as exc:
        return _die(f"{exc.message} No setup code was written.", 1)
    if args.dry_run:
        print(
            "Dry run. Would mint one unit, write /etc/tinywebstack/setup-code, "
            "write the lid QR, and enable tinyweb-setupd.service for the next boot."
        )
        print(f"control_plane={normalize_target}")
        print("No setup code was written. No family name or password was set.")
        return 0

    stage = Path(args.stage_dir) if args.stage_dir else None
    code_path = (stage / "setup-code") if stage else Path("/etc/tinywebstack/setup-code")
    qr_path = (stage / "setup-qr.svg") if stage else Path("/etc/tinywebstack/setup-qr.svg")
    if code_path.exists() or qr_path.exists():
        return _die(
            f"{code_path} or {qr_path} already exists. Refusing to replace a setup code.",
            1,
        )
    try:
        unit_text = _unit_text(normalize_target)
    except ControlPlaneError as exc:
        return _die(exc.message, 1)
    if not stage and os.geteuid() != 0:
        return _die("pre-ship.py must run as root (or pass --stage-dir). No setup code was written.", 1)

    try:
        minted = ControlPlaneClient(base).mint_unit(token)
        code, https_url, app_url = _urls_from_mint(minted)
    except ControlPlaneError as exc:
        extra = " No setup code was written."
        if exc.message.endswith("."):
            # Keep a single clear sentence when the message already says nothing was written.
            if "No setup code was written" in exc.message:
                extra = ""
        return _die(f"{exc.message}{extra}", 1)

    try:
        _atomic_secret(code_path, (code + "\n").encode("utf-8"))
    except OSError:
        return _die("Could not write the setup code. Check the directory and try again.", 1)
    try:
        write_qr(qr_path, https_url)
    except ImportError:
        print("Lid card and bottom sticker (same code):")
        print(https_url)
        print("App link, same code, not printed on the card:")
        print(app_url)
        print(f"wrote_code={code_path}")
        return _die(
            "The qrcode package is not installed, so no QR image was written. "
            "The URL above is the sticker. Nothing was written to a log file.",
            1,
        )
    except OSError:
        print(https_url)
        print(f"wrote_code={code_path}")
        return _die("The setup code was written, but the QR file was not.", 1)

    try:
        if stage:
            service_line = _stage_service(stage, unit_text)
        else:
            service_line = _enable_service(unit_text)
    except ControlPlaneError as exc:
        print(https_url)
        print(app_url)
        print(f"wrote_code={code_path}")
        return _die(exc.message, 1)

    # Stdout is the sticker sheet. Do not also send these lines to a log.
    print("Lid card and bottom sticker (same code):")
    print(https_url)
    print("App link, same code, not printed on the card:")
    print(app_url)
    print(f"wrote_code={code_path}")
    print(f"wrote_qr={qr_path}")
    print(service_line)
    print("No family name or parent password was set. No Matrix recovery key was printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
