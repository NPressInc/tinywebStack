"""Portal tile CLI values and install scripts (YunoHost 12 case sensitivity)."""

from pathlib import Path

from tinywebstack_family.portal_tiles import show_tile_cli_value

ROOT = Path(__file__).resolve().parents[3]


def test_show_tile_cli_value_uses_yunohost_casing() -> None:
    assert show_tile_cli_value(visible=True) == "True"
    assert show_tile_cli_value(visible=False) == "False"


def test_vm_scripts_do_not_use_lowercase_show_tile_false() -> None:
    scripts = list((ROOT / "scripts").rglob("*.sh"))
    offenders: list[str] = []
    for path in scripts:
        text = path.read_text(encoding="utf-8")
        if "--show_tile false" in text or "--show_tile true" in text:
            offenders.append(str(path.relative_to(ROOT)))
    assert offenders == []


def test_portal_tiles_helper_documents_true_false() -> None:
    helper = (ROOT / "scripts" / "lib" / "portal_tiles.sh").read_text(encoding="utf-8")
    assert "--show_tile False" in helper
    assert "--show_tile True" in helper
    assert "2>/dev/null" not in helper


def test_brand_portal_tile_pngs_ship_in_repo() -> None:
    assert (ROOT / "brand" / "portal" / "tinyweb-family-tile.png").is_file()
    assert (ROOT / "brand" / "portal" / "element-tile.png").is_file()


def test_portal_css_rewrites_family_home_tile_label() -> None:
    css = (ROOT / "brand" / "portal" / "tinyweb-portal.css").read_text(encoding="utf-8")
    assert 'content: "Family home"' in css
    assert 'href="/family/"' in css
