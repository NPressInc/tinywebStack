"""Hostname list stays aligned with scripts/lib/domains.sh."""

from __future__ import annotations

import subprocess

from tinyweb_controlplane.hosts import (
    advanced_certificate_hosts,
    node_all_domains,
    repo_root,
    split_proxy_hosts,
)


def _shell_hosts(main: str, *, jellyfin: bool) -> list[str]:
    domains = repo_root() / "scripts" / "lib" / "domains.sh"
    script = 'source "$1" && node_all_domains "$2"'
    env = {
        "PATH": "/usr/bin:/bin",
        "LOCATION_APP": "owntracks",
        "EVENTS_APP": "mobilizon",
        "TWS_PUSH_ENABLE": "1",
        "TWS_JELLYFIN": "1" if jellyfin else "0",
    }
    proc = subprocess.run(
        ["bash", "-c", script, "node_all_domains", str(domains), main],
        text=True,
        capture_output=True,
        check=False,
        env=env,
    )
    assert proc.returncode == 0, proc.stderr
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def test_python_list_matches_domains_sh() -> None:
    main = "smith.tinyweb.win"
    assert node_all_domains(main) == _shell_hosts(main, jellyfin=False)
    with_media = node_all_domains(main, jellyfin=True)
    assert with_media == _shell_hosts(main, jellyfin=True)
    proxied, excluded = split_proxy_hosts(with_media)
    assert excluded == ["jellyfin.smith.tinyweb.win"]
    assert "jellyfin.smith.tinyweb.win" not in proxied
    assert "matrix.smith.tinyweb.win" in proxied
    assert main in proxied


def test_advanced_certificate_includes_the_zone_apex_and_nested_wildcard() -> None:
    hosts = advanced_certificate_hosts("tinyweb.win", "smith.tinyweb.win")
    assert hosts == ["tinyweb.win", "smith.tinyweb.win", "*.smith.tinyweb.win"]
