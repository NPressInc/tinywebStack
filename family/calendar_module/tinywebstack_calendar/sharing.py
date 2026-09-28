"""CalDAV calendar sharing (WebDAV ACL extension used by Nextcloud Calendar)."""

from __future__ import annotations

import base64
import ssl
import urllib.error
import urllib.request
from typing import Literal
from xml.sax.saxutils import escape

Access = Literal["read", "read-write"]


def _access_element(access: Access) -> str:
    if access == "read-write":
        return '<x4:read-write xmlns:x4="http://calendarserver.org/ns/"/>'
    return '<x4:read xmlns:x4="http://calendarserver.org/ns/"/>'


def share_calendar_with_principal(
    calendar_url: str,
    owner_username: str,
    owner_password: str,
    principal_href: str,
    *,
    access: Access = "read-write",
    verify_ssl: bool = True,
    cafile: str | None = None,
) -> None:
    """Share a calendar with a user or group principal (Nextcloud CalDAV)."""
    calendar_url = calendar_url.rstrip("/") + "/"
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<x4:share xmlns:x4="http://calendarserver.org/ns/">
  <x4:set>
    <x0:href xmlns:x0="DAV:">{escape(principal_href)}</x0:href>
    {_access_element(access)}
  </x4:set>
</x4:share>"""
    auth = base64.b64encode(f"{owner_username}:{owner_password}".encode("utf-8")).decode("ascii")
    req = urllib.request.Request(
        calendar_url,
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/xml; charset=utf-8",
        },
    )
    ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
    if not verify_ssl:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            if resp.status not in (200, 201, 204):
                raise RuntimeError(f"unexpected share status {resp.status} for {calendar_url}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"calendar share failed ({exc.code}): {detail[:500]}") from exc


def group_principal(group: str) -> str:
    return f"principal:principals/groups/{group}"


def user_principal(username: str) -> str:
    return f"principal:principals/users/{username}"
