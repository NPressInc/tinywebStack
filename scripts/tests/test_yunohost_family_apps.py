"""Tests for scripts/vm/yunohost-family-apps.sh (no YunoHost VM)."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FAMILY_APPS = ROOT / "scripts" / "vm" / "yunohost-family-apps.sh"


def test_stale_owntracks_apt_cleanup_before_prep() -> None:
    text = FAMILY_APPS.read_text(encoding="utf-8")
    owntracks = text[text.find('if [[ "$LOCATION_APP" == "owntracks" ]]') : text.find("else", text.find("TRACCAR_ARGS"))]
    prep_idx = owntracks.find("prep-owntracks-apt.sh")
    list_idx = owntracks.find("/etc/apt/sources.list.d/owntracks.list")
    assert prep_idx >= 0 and list_idx >= 0 and list_idx < prep_idx
    assert "grep -qw owntracks" in owntracks[:prep_idx]
    assert "/etc/apt/preferences.d/owntracks" in owntracks
    assert "/etc/apt/trusted.gpg.d/owntracks.gpg" in owntracks
    assert "Removed stale OwnTracks apt artifacts" in owntracks


def test_family_groups_guards_traccar_with_app_installed() -> None:
    text = (ROOT / "scripts" / "vm" / "family-groups.sh").read_text(encoding="utf-8")
    assert "ynh_app_installed() {" in text
    assert "ynh_app_installed traccar" in text
    assert "ynh_app_installed owntracks" in text
    assert 'LOCATION_APP" == "traccar" ]] && ynh_app_installed traccar' in text


def test_stale_owntracks_apt_cleanup_skips_when_app_installed() -> None:
    text = FAMILY_APPS.read_text(encoding="utf-8")
    owntracks = text[text.find('if [[ "$LOCATION_APP" == "owntracks" ]]') : text.find("TRACCAR_ARGS")]
    cleanup = owntracks[: owntracks.find("prep-owntracks-apt.sh")]
    assert "if ! yunohost app list" in cleanup
    assert cleanup.count("grep -qw owntracks") >= 1
