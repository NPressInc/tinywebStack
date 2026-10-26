"""user-create adds members to tws-family* YunoHost groups."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "vm" / "family-dashboard-privileged.sh"


def test_user_create_adds_tws_family_groups() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    assert "TWS_FAMILY_GROUPS" in text
    assert "tws-family" in text
    assert "yunohost user group list --output-as json" in text
    assert 'yunohost_group_add "$fam_grp" "$USER"' in text
