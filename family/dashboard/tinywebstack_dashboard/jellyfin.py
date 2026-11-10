"""Optional Jellyfin discovery and the packaged LDAP new-user default.

TinyWeb does not talk to the Jellyfin admin API and does not store an API key.
Library access, metadata, and playback stay in Jellyfin. This module only:

- publishes a public server URL (no credentials) when Jellyfin was installed
- rewrites the official YunoHost LDAP plugin config so a newly created Jellyfin
  account does not start with every library

The login gate itself is the official plugin search filter, which requires the
YunoHost permission ``jellyfin.main``. Children are not granted that permission
by the installer. A native Jellyfin client uses the same LDAP login, so it
cannot skip that check.

Verified against YunoHost-Apps/jellyfin_ynh master on 2026-11-10
(package 12.4~ynh1, LDAP plugin 24.0.0.0):

- ``manifest.toml`` sets catalog flags ``ldap = true`` and ``sso = true``, but
  ``main.auth_header = false`` and the install help says Jellyfin has its own
  login. ``doc/ADMIN.md`` says users log in through LDAP and need ``main``.
- ``conf/LDAP-Auth.xml`` ships ``CreateUsersFromLdap`` true and
  ``EnableAllFolders`` true, plus two hardcoded library ids.
- Plugin 24 source sets ``EnableAllFolders`` from that config when it creates a
  user (``LDAPAuthenticationProviderPlugin``), then calls ``UpdateUserAsync``.
- Upstream issue jellyfin-plugin-ldapauth#221 (plugin 23 on server 10.11) reports
  that flag was ignored. It was still open, and 24.0.0.0's changelog does not
  mention a fix. TinyWeb therefore does not treat the XML flag as the only
  control: children are also left off ``jellyfin.main``.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from typing import Any, Dict, Mapping, Optional
from urllib.parse import urlparse

# Official packaged filter (conf/LDAP-Auth.xml). Login matches only LDAP users
# who hold this YunoHost permission. It is not an HTTP header the client sets.
LDAP_MAIN_PERMISSION_FILTER = (
    "(permission=cn=jellyfin.main,ou=permission,dc=yunohost,dc=org)"
)
LDAP_ADMIN_PERMISSION_FILTER = (
    "(permission=cn=jellyfin.admin,ou=permission,dc=yunohost,dc=org)"
)


def ldap_login_permitted(*, has_jellyfin_main: bool) -> bool:
    """Whether the official LDAP search filter can authenticate this account.

    A native client and the browser send the same username and password. Neither
    can grant itself ``jellyfin.main``. Without that permission the plugin's
    search filter does not return the account, so no Jellyfin session is created
    and no library list is returned.
    """

    return bool(has_jellyfin_main)


def jellyfin_public_discovery(url: Optional[str]) -> Dict[str, Any]:
    """Public discovery document. Never includes credentials or an API key.

    ``sso`` is always false. Matching LDAP passwords are not a YunoHost session
    inside Jellyfin. ``quiet_hours_enforced`` is always false: TinyWeb does not
    set Jellyfin access schedules.
    """

    disabled: Dict[str, Any] = {
        "enabled": False,
        "sso": False,
        "auth": "unavailable",
        "quiet_hours_enforced": False,
    }
    raw = (url or "").strip()
    if not raw:
        return disabled
    parsed = urlparse(raw)
    host = parsed.hostname
    if parsed.scheme != "https" or not host or parsed.username or parsed.password:
        return disabled
    if parsed.query or parsed.fragment:
        return disabled
    port = f":{parsed.port}" if parsed.port else ""
    path = parsed.path or "/"
    if not path.startswith("/"):
        path = "/" + path
    if not path.endswith("/"):
        path = path + "/"
    return {
        "enabled": True,
        "url": f"https://{host}{port}{path}",
        "sso": False,
        "auth": "ldap_password",
        "quiet_hours_enforced": False,
    }


def _element(parent: ET.Element, name: str) -> ET.Element:
    found = parent.find(name)
    if found is None:
        raise ValueError(
            f"LDAP config has no {name} element; refusing to claim a secure Jellyfin default"
        )
    return found


def apply_secure_ldap_defaults(xml_text: str) -> str:
    """Turn off all-library access for accounts the LDAP plugin creates.

    Leaves the search filter, bind settings, and ``CreateUsersFromLdap`` as the
    package wrote them. Clears ``EnabledFolders`` so packaged placeholder library
    ids are not granted. Raises if the expected elements are missing.
    """

    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        raise ValueError("LDAP config is not XML") from exc
    enable = _element(root, "EnableAllFolders")
    folders = _element(root, "EnabledFolders")
    enable.text = "false"
    for child in list(folders):
        folders.remove(child)
    if root.find("CreateUsersFromLdap") is None:
        raise ValueError(
            "LDAP config has no CreateUsersFromLdap element; refusing to claim a secure Jellyfin default"
        )
    declaration = "<?xml version='1.0' encoding='utf-8'?>\n"
    body = ET.tostring(root, encoding="unicode")
    return declaration + body + "\n"


def ldap_new_user_library_default(xml_text: str) -> Mapping[str, Any]:
    """Read the new-user library default back from plugin XML."""

    root = ET.fromstring(xml_text)
    enable = _element(root, "EnableAllFolders")
    folders = _element(root, "EnabledFolders")
    ids = [((node.text or "").strip()) for node in list(folders) if (node.text or "").strip()]
    return {
        "enable_all_folders": (enable.text or "").strip().lower() == "true",
        "enabled_folders": ids,
    }


def assert_secure_ldap_defaults(xml_text: str) -> None:
    state = ldap_new_user_library_default(xml_text)
    if state["enable_all_folders"] or state["enabled_folders"]:
        raise ValueError(
            "Jellyfin LDAP new-user default still grants libraries; child login must stay disabled"
        )


def secure_ldap_config_file(path: str) -> str:
    """Rewrite ``path`` in place. Returns ``updated`` or ``unchanged``.

    Does not print the file. The packaged XML has an empty bind password; this
    function still treats the file as private and writes it back atomically.
    """

    from pathlib import Path
    import os

    file_path = Path(path)
    original = file_path.read_text(encoding="utf-8")
    updated = apply_secure_ldap_defaults(original)
    assert_secure_ldap_defaults(updated)
    if updated == original:
        return "unchanged"
    tmp = file_path.with_suffix(file_path.suffix + ".tmp")
    tmp.write_text(updated, encoding="utf-8")
    os.chmod(tmp, 0o640)
    os.replace(tmp, file_path)
    return "updated"


def main(argv: Optional[list[str]] = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Secure the packaged Jellyfin LDAP new-user default")
    parser.add_argument("--secure-ldap-xml", required=True)
    args = parser.parse_args(argv)
    try:
        status = secure_ldap_config_file(args.secure_ldap_xml)
    except (OSError, ValueError) as exc:
        print(f"jellyfin ldap default not secured: {exc}", file=sys.stderr)
        return 1
    print(status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
