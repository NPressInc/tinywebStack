"""Hostnames for one family, taken from scripts/lib/domains.sh.

That file is the hostname list the installer and the DDNS helper already use.
When Jellyfin is enabled there, jellyfin.<family> is part of the same list and
is placed on the tunnel with the other service hosts. Immich is not in the list.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

# cloudflared connects to the box's local nginx. The phone validates Cloudflare's
# edge certificate, not this hop. 127.0.0.1 will not match the public certificate
# name, so the tunnel config sets noTLSVerify on the origin request.
TUNNEL_ORIGIN_SERVICE = "https://127.0.0.1:443"

UNIVERSAL_SSL_NOTE = (
    "Universal SSL covers the zone apex and the first label only "
    "(tinyweb.win and *.tinyweb.win). Nested names such as "
    "matrix.<family>.tinyweb.win need Advanced Certificate Manager "
    "or Total TLS."
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def node_all_domains(
    main_domain: str,
    *,
    location_app: str = "owntracks",
    events_app: str = "mobilizon",
    push: bool = True,
    jellyfin: bool = False,
) -> list[str]:
    """Return the installer's hostname list for main_domain."""
    domains_sh = repo_root() / "scripts" / "lib" / "domains.sh"
    env = os.environ.copy()
    env["LOCATION_APP"] = location_app
    env["EVENTS_APP"] = events_app
    env["TWS_PUSH_ENABLE"] = "1" if push else "0"
    env["TWS_JELLYFIN"] = "1" if jellyfin else "0"
    # Drop the operator environment so a box-side Cloudflare token cannot leak
    # into a hostname lookup, and so local.env is not required.
    for key in ("CF_API_TOKEN", "CF_ZONE_ID", "CF_ACCOUNT_ID", "TWS_DDNS_TOKEN"):
        env.pop(key, None)
    script = 'source "$1" && node_all_domains "$2"'
    proc = subprocess.run(
        ["bash", "-c", script, "node_all_domains", str(domains_sh), main_domain],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or "node_all_domains failed"
        raise RuntimeError(detail)
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def split_proxy_hosts(hostnames: list[str]) -> tuple[list[str], list[str]]:
    """Proxy every hostname the installer listed, including Jellyfin when enabled.

    The installer omits jellyfin.<family> unless TWS_JELLYFIN is on. Immich is
    not a v1 hostname, so it is never in this list.
    """
    return list(hostnames), []


def advanced_certificate_hosts(base_domain: str, family_domain: str) -> list[str]:
    """Hosts for one Advanced Certificate Manager pack.

    The API requires the zone apex on every pack. The wildcard covers one
    further label (matrix.<family>, push.<family>, and the rest). The family
    apex is listed on its own because a wildcard does not cover it.
    """
    hosts = [base_domain, family_domain, f"*.{family_domain}"]
    seen: list[str] = []
    for host in hosts:
        if host not in seen:
            seen.append(host)
    return seen
