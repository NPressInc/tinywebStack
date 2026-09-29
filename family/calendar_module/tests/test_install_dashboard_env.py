from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def test_install_family_dashboard_updates_caldav_root_on_existing_env() -> None:
    text = (ROOT / "scripts" / "vm" / "install-family-dashboard.sh").read_text(encoding="utf-8")
    assert "TWS_CALDAV_ROOT=" in text
    assert 'grep -q \'^TWS_CALDAV_ROOT=\'' in text


def test_family_groups_keeps_nextcloud_visitors() -> None:
    text = (ROOT / "scripts" / "vm" / "family-groups.sh").read_text(encoding="utf-8")
    assert "perm_add nextcloud.main visitors" in text
    assert "perm_remove nextcloud.main visitors" not in text


def test_nextcloud_install_uses_visitors_permission() -> None:
    text = (ROOT / "scripts" / "vm" / "install-nextcloud-calendar.sh").read_text(encoding="utf-8")
    assert "init_main_permission=visitors" in text
    assert "init_main_permission=all_users" not in text


def test_verify_calendar_script_resolves_repo_root() -> None:
    text = (ROOT / "scripts" / "spark" / "verify-calendar-e2e.sh").read_text(encoding="utf-8")
    assert "tw_stack_root_from_script_dir" in text
    assert "family/calendar_module" in (ROOT / "scripts" / "lib" / "tw_stack_root.sh").read_text(encoding="utf-8")
    assert "TWS_CALENDAR_VERIFY_PARENT_PASSWORD" in text
    assert '--password "$PARENT_PASSWORD"' not in text
