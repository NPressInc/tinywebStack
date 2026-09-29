import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def test_all_scripts_sh_are_executable_in_git_index() -> None:
    out = subprocess.check_output(["git", "ls-files", "-s", "scripts"], cwd=ROOT, text=True)
    bad: list[str] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        mode, _hash, _stage, path = parts[0], parts[1], parts[2], parts[3]
        if not path.endswith(".sh"):
            continue
        if mode != "100755":
            bad.append(f"{path} ({mode})")
    assert bad == [], "non-executable shell scripts in git index:\n" + "\n".join(bad)
