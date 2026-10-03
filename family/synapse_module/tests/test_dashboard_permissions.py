"""Permission setup logic (YunoHost 12 API names)."""

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import setup_family_dashboard_perms as perms  # noqa: E402


def test_setup_calls_permission_create_with_yunohost12_api():
    fake_mod = MagicMock()
    fake_mod.user_permission_list.return_value = {"permissions": {}}
    with patch.dict(
        "sys.modules",
        {
            "yunohost": MagicMock(),
            "yunohost.permission": fake_mod,
        },
    ):
        import importlib

        importlib.reload(perms)
        perms.setup_family_dashboard_permissions("synapse", "parents", create_owntracks_pub=False)
    assert fake_mod.permission_create.call_count >= 2
    assert "permission_url_add" not in dir(fake_mod)
    created = {c[0][0]: c[1] for c in fake_mod.permission_create.call_args_list}
    assert "synapse.family_dashboard" in created
    assert created["synapse.family_dashboard"]["url"] == "/family"
    assert created["synapse.family_dashboard"]["show_tile"] is True


def test_setup_updates_existing_permission_urls():
    fake_mod = MagicMock()
    fake_mod.user_permission_list.return_value = {
        "permissions": {
            "synapse.family_dashboard": {},
            "synapse.family_public": {},
        },
    }
    with patch.dict(
        "sys.modules",
        {
            "yunohost": MagicMock(),
            "yunohost.permission": fake_mod,
        },
    ):
        import importlib

        importlib.reload(perms)
        perms.setup_family_dashboard_permissions("synapse", "parents", create_owntracks_pub=False)
    assert fake_mod.permission_create.call_count == 0
    assert fake_mod.permission_url.call_count == 2


def test_setup_with_main_domain_uses_absolute_urls_on_create():
    fake_mod = MagicMock()
    fake_mod.user_permission_list.return_value = {"permissions": {}}
    with patch.dict(
        "sys.modules",
        {
            "yunohost": MagicMock(),
            "yunohost.permission": fake_mod,
        },
    ):
        import importlib

        importlib.reload(perms)
        perms.setup_family_dashboard_permissions(
            "synapse",
            "parents",
            create_owntracks_pub=False,
            main_domain="home.example.com",
        )
    created = {c[0][0]: c[1] for c in fake_mod.permission_create.call_args_list}
    assert created["synapse.family_dashboard"]["url"] == "home.example.com/family"
    pub = created["synapse.family_public"]
    assert pub["url"] == "home.example.com/family/api/invite/verify"
    assert pub["additional_urls"] == ["home.example.com/.well-known/tinywebstack-family.json"]


def test_setup_with_main_domain_uses_absolute_urls_on_update():
    fake_mod = MagicMock()
    fake_mod.user_permission_list.return_value = {
        "permissions": {
            "synapse.family_dashboard": {},
            "synapse.family_public": {},
        },
    }
    with patch.dict(
        "sys.modules",
        {
            "yunohost": MagicMock(),
            "yunohost.permission": fake_mod,
        },
    ):
        import importlib

        importlib.reload(perms)
        perms.setup_family_dashboard_permissions(
            "synapse",
            "parents",
            create_owntracks_pub=False,
            main_domain="home.example.com",
        )
    assert fake_mod.permission_create.call_count == 0
    assert fake_mod.permission_url.call_count == 2
    by_name = {c[0][0]: c[1] for c in fake_mod.permission_url.call_args_list}
    dash = by_name["synapse.family_dashboard"]
    assert "clear_urls" not in dash
    assert dash["url"] == "home.example.com/family"
    pub = by_name["synapse.family_public"]
    assert "clear_urls" not in pub
    assert pub["url"] == "home.example.com/family/api/invite/verify"
    assert pub["set_url"] == ["home.example.com/.well-known/tinywebstack-family.json"]
