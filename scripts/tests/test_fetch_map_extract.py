import os
import stat
import subprocess
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/lib/fetch-map-extract.sh"


def _run_script(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    merged.update(env)
    merged["TW_STACK_ROOT"] = str(REPO)
    merged.setdefault("TWS_MAP_SOURCE_URL", "https://build.protomaps.com/20990101.pmtiles")
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO,
        env=merged,
        capture_output=True,
        text=True,
        check=False,
    )


def test_fetch_map_extract_dry_run_skips_without_bbox():
    env = {
        "TWS_MAP_BBOX": "",
        "TWS_MAP_REGION": "",
    }
    for key in ("TWS_MAP_BBOX", "TWS_MAP_REGION"):
        env.pop(key, None)
    proc = subprocess.run(
        ["bash", str(SCRIPT), "--dry-run"],
        cwd=REPO,
        env={k: v for k, v in os.environ.items() if k not in ("TWS_MAP_BBOX", "TWS_MAP_REGION")},
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    assert "Skipping map extract" in proc.stdout + proc.stderr


def test_fetch_map_extract_dry_run_with_preset():
    proc = _run_script(
        {
            "TWS_MAP_REGION": "colorado-front-range",
            "TWS_MAP_MAXZOOM": "12",
            "TWS_MAP_SOURCE_URL": "",
            "TWS_MAP_BUILD_DATE": "",
        },
        "--dry-run",
    )
    assert proc.returncode == 0
    combined = proc.stdout + proc.stderr
    assert "pmtiles extract" in combined
    assert "--bbox=-109.2,39.5,-104.5,41.2" in combined
    assert "--maxzoom=12" in combined
    assert "would probe https://build.protomaps.com/<YYYYMMDD>.pmtiles" in combined


def test_fetch_map_extract_keeps_basemap_and_meta_after_assets(tmp_path: Path):
    fake_pmtiles = tmp_path / "fake-pmtiles.sh"
    fake_pmtiles.write_text(
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "$1" == "extract" ]]; then
              printf 'pmtiles-extract-stub\\n' >"$3"
              exit 0
            fi
            exit 1
            """
        ),
        encoding="utf-8",
    )
    fake_pmtiles.chmod(fake_pmtiles.stat().st_mode | stat.S_IXUSR)

    map_dir = tmp_path / "map"
    map_dir.mkdir()
    basemap = map_dir / "basemap.pmtiles"
    meta = map_dir / "map.meta.json"
    basemap.write_text("existing-basemap\n", encoding="utf-8")
    meta.write_text('{"bounds":[0,0,1,1]}\n', encoding="utf-8")

    proc = _run_script(
        {
            "TWS_MAP_BBOX": "1,2,3,4",
            "TWS_MAP_DATA_DIR": str(map_dir),
            "TWS_PMTILES_BIN": str(fake_pmtiles),
            "TWS_MAP_SOURCE_URL": "file:///dev/null",
        },
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr

    assert basemap.is_file()
    assert meta.is_file()
    assert "pmtiles-extract-stub" in basemap.read_text(encoding="utf-8")
    assert '"bounds": [1, 2, 3, 4]' in meta.read_text(encoding="utf-8")
    assert (map_dir / "style.json").is_file()
