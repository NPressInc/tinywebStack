import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def test_node_all_domains_includes_nextcloud() -> None:
    script = ROOT / "scripts" / "lib" / "domains.sh"
    out = subprocess.check_output(
        ["bash", "-c", f'source "{script}"; node_all_domains family-a.family.test'],
        text=True,
    )
    names = set(out.strip().splitlines())
    assert "nextcloud.family-a.family.test" in names
