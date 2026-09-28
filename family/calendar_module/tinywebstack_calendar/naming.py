"""Naming conventions for family calendars and YunoHost groups."""

from __future__ import annotations

CALENDAR_IDS = {
    "family": "tws-family",
    "parents": "tws-parents",
    "kids": "tws-kids",
}

CALENDAR_DISPLAY = {
    "family": "Family",
    "parents": "Parents",
    "kids": "Kids",
}


def node_slug(main_domain: str, node_name: str | None = None) -> str:
    if node_name:
        return node_name.strip().lower()
    return main_domain.split(".", 1)[0].lower()


def family_group_name(main_domain: str, node_name: str | None = None) -> str:
    """YunoHost group for the whole household (parents + kids)."""
    return f"family-{node_slug(main_domain, node_name)}"


def nextcloud_domain(main_domain: str) -> str:
    return f"nextcloud.{main_domain}"


def nextcloud_web_base(main_domain: str, path: str = "/nextcloud") -> str:
    host = nextcloud_domain(main_domain)
    return f"https://{host}{path.rstrip('/')}"


def caldav_root(main_domain: str, path: str = "/nextcloud") -> str:
    return f"{nextcloud_web_base(main_domain, path)}/remote.php/dav"


def principal_calendar_url(main_domain: str, username: str, calendar_id: str, path: str = "/nextcloud") -> str:
    return f"{caldav_root(main_domain, path)}/calendars/{username}/{calendar_id}/"
