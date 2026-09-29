"""CalDAV calendar sharing (Nextcloud uses ownCloud WebDAV share extension)."""

from __future__ import annotations

import base64
import re
import ssl
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from typing import Literal, Set
from xml.sax.saxutils import escape

Access = Literal["read", "read-write"]

OC_NS = "http://owncloud.org/ns"
DAV_NS = "DAV:"


def _access_element(access: Access) -> str:
    if access == "read-write":
        return f'<oc:read-write xmlns:oc="{OC_NS}"/>'
    return f'<oc:read xmlns:oc="{OC_NS}"/>'


def share_request_body(principal_href: str, *, access: Access = "read-write") -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<oc:share xmlns:oc="{OC_NS}">
  <oc:set>
    <x0:href xmlns:x0="{DAV_NS}">{escape(principal_href)}</x0:href>
    {_access_element(access)}
  </oc:set>
</oc:share>"""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def _ssl_context(*, verify_ssl: bool, cafile: str | None) -> ssl.SSLContext:
    if not verify_ssl:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if cafile:
        return ssl.create_default_context(cafile=cafile)
    return ssl.create_default_context()


def _basic_auth_header(username: str, password: str) -> str:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {token}"


def _open_caldav(
    url: str,
    *,
    method: str,
    username: str,
    password: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    verify_ssl: bool = True,
    cafile: str | None = None,
) -> tuple[int, str, dict[str, str]]:
    hdrs = {
        "Authorization": _basic_auth_header(username, password),
        **(headers or {}),
    }
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    ctx = _ssl_context(verify_ssl=verify_ssl, cafile=cafile)
    opener = urllib.request.build_opener(_NoRedirect, urllib.request.HTTPSHandler(context=ctx))
    try:
        with opener.open(req, timeout=60) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            return resp.status, text, dict(resp.headers)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        if exc.code in (301, 302, 303, 307, 308):
            location = exc.headers.get("Location", "")
            raise RuntimeError(
                f"unexpected redirect ({exc.code}) to {location!r} for {url} — "
                "check YunoHost nextcloud.main permissions (CalDAV needs visitors or public DAV path)"
            ) from exc
        raise RuntimeError(f"CalDAV request failed ({exc.code}): {detail[:500]}") from exc


def _parse_principal_hrefs_from_propfind(text: str) -> Set[str]:
    sharees: Set[str] = set()
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return sharees
    for elem in root.iter():
        tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
        if tag == "href" and elem.text and "principal:" in elem.text:
            sharees.add(elem.text.strip())
    return sharees


def list_calendar_sharees(
    calendar_url: str,
    owner_username: str,
    owner_password: str,
    *,
    verify_ssl: bool = True,
    cafile: str | None = None,
) -> Set[str]:
    """Return principal hrefs already shared on this calendar (Nextcloud oc:invite)."""
    calendar_url = calendar_url.rstrip("/") + "/"
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="{DAV_NS}" xmlns:oc="{OC_NS}">
  <d:prop><oc:invite/></d:prop>
</d:propfind>"""
    try:
        _status, text, _hdrs = _open_caldav(
            calendar_url,
            method="PROPFIND",
            username=owner_username,
            password=owner_password,
            body=body.encode("utf-8"),
            headers={"Depth": "0", "Content-Type": "application/xml; charset=utf-8"},
            verify_ssl=verify_ssl,
            cafile=cafile,
        )
    except RuntimeError as exc:
        if "404" in str(exc):
            return set()
        raise
    return _parse_principal_hrefs_from_propfind(text)


def set_calendar_display_name(
    calendar_url: str,
    owner_username: str,
    owner_password: str,
    display_name: str,
    *,
    verify_ssl: bool = True,
    cafile: str | None = None,
) -> None:
    """Set DAV displayname on a calendar collection (idempotent)."""
    calendar_url = calendar_url.rstrip("/") + "/"
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="{DAV_NS}">
  <d:set>
    <d:prop>
      <d:displayname>{escape(display_name)}</d:displayname>
    </d:prop>
  </d:set>
</d:propertyupdate>"""
    _open_caldav(
        calendar_url,
        method="PROPPATCH",
        username=owner_username,
        password=owner_password,
        body=body.encode("utf-8"),
        headers={"Content-Type": "application/xml; charset=utf-8"},
        verify_ssl=verify_ssl,
        cafile=cafile,
    )


def share_calendar_with_principal(
    calendar_url: str,
    owner_username: str,
    owner_password: str,
    principal_href: str,
    *,
    access: Access = "read-write",
    verify_ssl: bool = True,
    cafile: str | None = None,
    skip_if_shared: bool = True,
) -> bool:
    """Share a calendar with a user or group principal. Returns True if a new share was created."""
    calendar_url = calendar_url.rstrip("/") + "/"
    if skip_if_shared:
        existing = list_calendar_sharees(
            calendar_url,
            owner_username,
            owner_password,
            verify_ssl=verify_ssl,
            cafile=cafile,
        )
        if principal_href in existing:
            return False

    body = share_request_body(principal_href, access=access)
    status, _text, _hdrs = _open_caldav(
        calendar_url,
        method="POST",
        username=owner_username,
        password=owner_password,
        body=body.encode("utf-8"),
        headers={"Content-Type": "application/xml; charset=utf-8"},
        verify_ssl=verify_ssl,
        cafile=cafile,
    )
    if status not in (200, 201, 204):
        raise RuntimeError(f"unexpected share status {status} for {calendar_url}")
    return True


def group_principal(group: str) -> str:
    return f"principal:principals/groups/{group}"


def user_principal(username: str) -> str:
    return f"principal:principals/users/{username}"


def principal_suffix(href: str) -> str:
    m = re.search(r"principals/(groups|users)/(.+)$", href)
    return m.group(2) if m else href
