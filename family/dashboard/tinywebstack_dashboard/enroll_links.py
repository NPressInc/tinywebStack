"""One-time phone setup links. The code may appear in the link; passwords must not."""

from __future__ import annotations

import base64
import io
import re

_HOST_RE = re.compile(r"^[A-Za-z0-9.-]+(?::\d+)?$")

CODE_EXPIRED_MESSAGE = (
    "This code has expired. Ask a parent for a new one. Codes last about 10 minutes."
)
CODE_USED_MESSAGE = "This code was already used. Ask a parent for a new one."
INVALID_CODE_MESSAGE = (
    "This code doesn't work on this family server. "
    "Check the family name matches the parent's screen, or ask for a new code."
)


def build_enroll_links(server_name: str, code: str) -> dict[str, str]:
    """HTTPS join link (code in the fragment) and the app deep link.

    The fragment is not sent to the server, so access logs do not record the code.
    Neither URL carries a password or session token.
    """
    host = _safe_host(server_name)
    safe_code = code.strip()
    join = f"https://{host}/family/join#code={safe_code}"
    deep = f"tinyweb://enroll?server={host}&code={safe_code}"
    return {"qr_payload": join, "deep_link": deep, "join_url": join}


def _safe_host(server_name: str) -> str:
    host = server_name.strip()
    if not _HOST_RE.fullmatch(host):
        raise ValueError("server name is not a hostname")
    return host


def enroll_qr_data_uri(payload: str) -> str:
    """PNG data URI so the code is not placed in a second image URL."""
    import qrcode

    img = qrcode.make(payload)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    encoded = base64.standard_b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/png;base64,{encoded}"
