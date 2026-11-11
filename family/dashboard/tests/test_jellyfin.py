"""Jellyfin stays optional: public discovery, no secrets, deny-by-default libraries."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.jellyfin import (
    LDAP_MAIN_PERMISSION_FILTER,
    apply_secure_ldap_defaults,
    assert_secure_ldap_defaults,
    jellyfin_public_discovery,
    ldap_login_permitted,
    ldap_new_user_library_default,
    secure_ldap_config_file,
)

# The official package file (YunoHost-Apps/jellyfin_ynh conf/LDAP-Auth.xml,
# package 12.4~ynh1). Bind passwords are empty in the packaged template.
PACKAGED_LDAP_XML = """<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LdapServer>127.0.0.1</LdapServer>
  <LdapPort>389</LdapPort>
  <LdapBindUser />
  <LdapBindPassword />
  <LdapBaseDn>ou=users,dc=yunohost,dc=org</LdapBaseDn>
  <LdapSearchFilter>(permission=cn=jellyfin.main,ou=permission,dc=yunohost,dc=org)</LdapSearchFilter>
  <LdapAdminFilter>(permission=cn=jellyfin.admin,ou=permission,dc=yunohost,dc=org)</LdapAdminFilter>
  <CreateUsersFromLdap>true</CreateUsersFromLdap>
  <EnableAllFolders>true</EnableAllFolders>
  <EnabledFolders>
    <string>db36da0754ef18efa77eabef2d57a80d</string>
    <string>db4c1708cbb5dd1676284a40f2950aba</string>
  </EnabledFolders>
</PluginConfiguration>
"""

ROOT = Path(__file__).resolve().parents[3]


def test_packaged_default_grants_every_library_until_we_rewrite_it() -> None:
    before = ldap_new_user_library_default(PACKAGED_LDAP_XML)
    assert before["enable_all_folders"] is True
    assert "db36da0754ef18efa77eabef2d57a80d" in before["enabled_folders"]
    secured = apply_secure_ldap_defaults(PACKAGED_LDAP_XML)
    assert_secure_ldap_defaults(secured)
    after = ldap_new_user_library_default(secured)
    assert after == {"enable_all_folders": False, "enabled_folders": []}
    assert "db36da0754ef18efa77eabef2d57a80d" not in secured
    assert "db4c1708cbb5dd1676284a40f2950aba" not in secured
    assert LDAP_MAIN_PERMISSION_FILTER in secured
    assert "<CreateUsersFromLdap>true</CreateUsersFromLdap>" in secured


def test_secure_ldap_file_is_idempotent_and_does_not_print_the_file(tmp_path, capsys) -> None:
    path = tmp_path / "LDAP-Auth.xml"
    path.write_text(PACKAGED_LDAP_XML, encoding="utf-8")
    assert secure_ldap_config_file(str(path)) == "updated"
    assert secure_ldap_config_file(str(path)) == "unchanged"
    captured = capsys.readouterr()
    assert "db36da0754ef18efa77eabef2d57a80d" not in captured.out
    assert "LdapBindPassword" not in captured.out


def test_unknown_ldap_schema_is_refused() -> None:
    try:
        apply_secure_ldap_defaults("<PluginConfiguration></PluginConfiguration>")
    except ValueError as exc:
        assert "EnableAllFolders" in str(exc)
    else:
        raise AssertionError("missing EnableAllFolders must fail closed")


def test_native_client_cannot_log_in_without_jellyfin_main() -> None:
    assert ldap_login_permitted(has_jellyfin_main=False) is False
    assert ldap_login_permitted(has_jellyfin_main=True) is True


def test_discovery_never_carries_secrets_or_sso() -> None:
    off = jellyfin_public_discovery(None)
    assert off["enabled"] is False
    assert off["sso"] is False
    assert off["quiet_hours_enforced"] is False
    on = jellyfin_public_discovery("https://jellyfin.smith.tinyweb.win")
    blob = json.dumps(on)
    assert on["url"] == "https://jellyfin.smith.tinyweb.win/"
    assert on["sso"] is False
    assert on["auth"] == "ldap_password"
    assert on["quiet_hours_enforced"] is False
    assert "api_key" not in blob
    assert "token" not in blob
    assert "secret" not in blob
    refused = jellyfin_public_discovery("https://user:secret@jellyfin.smith.tinyweb.win/?api_key=abc")
    assert refused["enabled"] is False
    assert "secret" not in json.dumps(refused)


def test_well_known_and_home_stay_quiet_until_jellyfin_is_configured(tmp_path, monkeypatch) -> None:
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps({"server_name": "smith.tinyweb.win", "kids": {}, "parent_mxids": ["@p:smith.tinyweb.win"]}),
        encoding="utf-8",
    )
    monkeypatch.delenv("TWS_JELLYFIN_URL", raising=False)
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": ["parent1"], "kids": []}))
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_LIST_USERS",
        json.dumps({"users": {"parent1": {"groups": ["parents"]}}}),
    )
    app = create_app(
        DashboardConfig(
            policy_path=str(policy),
            server_name="smith.tinyweb.win",
            csrf_secret="test-secret",
        )
    )
    client = TestClient(app)
    known = client.get("/.well-known/tinywebstack-family.json").json()
    assert known["jellyfin"]["enabled"] is False
    assert known["jellyfin"]["sso"] is False
    home = client.get("/", headers={"YNH_USER": "parent1"})
    assert home.status_code == 200
    assert "Open Jellyfin" not in home.text
    assert "api_key" not in home.text.lower()

    monkeypatch.setenv("TWS_JELLYFIN_URL", "https://jellyfin.smith.tinyweb.win/")
    known_on = client.get("/.well-known/tinywebstack-family.json").json()
    assert known_on["jellyfin"]["url"] == "https://jellyfin.smith.tinyweb.win/"
    assert known_on["jellyfin"]["sso"] is False
    home_on = client.get("/", headers={"YNH_USER": "parent1"})
    assert "Open Jellyfin" in home_on.text
    assert "not single sign-on" in home_on.text
    assert "no libraries" in home_on.text
    assert "quiet hours do not apply" in home_on.text
    assert "jellyfin.main" in home_on.text
    assert "EnabledFolders" not in home_on.text
    assert "secret" not in home_on.text.lower()


def test_installer_leaves_jellyfin_off_the_default_domain_list() -> None:
    script = ROOT / "scripts" / "lib" / "domains.sh"
    text = script.read_text(encoding="utf-8")
    assert "jellyfin_domain()" in text
    assert "jellyfin_requested" in text
    install = (ROOT / "scripts" / "vm" / "install-jellyfin.sh").read_text(encoding="utf-8")
    assert "TWS_JELLYFIN is off" in install
    assert "cloudflared-hosts.sh" in install
    assert "sync_jellyfin_tunnel 0" in install
    assert "sync_jellyfin_tunnel 1" in install
    assert "init_main_permission=visitors" in install
    assert "path=/" in install
    assert "init_admin_permission=" in install
    assert "--secure-ldap-xml" in install
    assert "password=" not in install.lower()
    assert "api_key" not in install.lower()
    groups = (ROOT / "scripts" / "vm" / "family-groups.sh").read_text(encoding="utf-8")
    start = groups.find("ynh_app_installed jellyfin")
    assert start > 0
    block = groups[start : groups.find("configure_element_tile_logo", start)]
    assert 'perm_add jellyfin.main "$PARENTS_GROUP"' in block
    assert 'perm_add jellyfin.admin "$PARENTS_GROUP"' in block
    assert 'perm_remove jellyfin.main "$KIDS_GROUP"' in block
    assert 'perm_remove jellyfin.admin "$KIDS_GROUP"' in block
    assert 'perm_remove jellyfin.main "$FED_TEST_GROUP"' in block
    assert 'perm_add jellyfin.main "$KIDS_GROUP"' not in block
    assert 'perm_add jellyfin.admin "$KIDS_GROUP"' not in block
    assert 'perm_add jellyfin.main "$FED_TEST_GROUP"' not in block
    init = (ROOT / "scripts" / "vm" / "family-init.sh").read_text(encoding="utf-8")
    assert "install-jellyfin.sh" in init


def test_disabled_install_exits_before_changing_the_box() -> None:
    script = ROOT / "scripts" / "vm" / "install-jellyfin.sh"
    env = os.environ.copy()
    env["TWS_JELLYFIN"] = "0"
    env["TW_STACK_SKIP_LOCAL_ENV"] = "1"
    result = subprocess.run(
        ["bash", str(script), "smith.tinyweb.win"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "Jellyfin install skipped" in result.stderr
    assert "yunohost app install" not in result.stderr


def test_domain_list_includes_jellyfin_only_when_requested() -> None:
    script = ROOT / "scripts" / "lib" / "domains.sh"
    off = subprocess.check_output(
        ["bash", "-c", f'source "{script}"; node_all_domains smith.tinyweb.win'],
        text=True,
        env={**os.environ, "TWS_JELLYFIN": "0"},
    )
    assert "jellyfin.smith.tinyweb.win" not in off.split()
    on = subprocess.check_output(
        ["bash", "-c", f'source "{script}"; node_all_domains smith.tinyweb.win'],
        text=True,
        env={**os.environ, "TWS_JELLYFIN": "1"},
    )
    assert "jellyfin.smith.tinyweb.win" in on.split()
