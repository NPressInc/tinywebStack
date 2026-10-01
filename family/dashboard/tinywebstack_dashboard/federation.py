"""Trusted-domain (Matrix federation allowlist) state + dashboard router.

The JSON state file is the dashboard-side source of truth for trusted peer
domains (L2.2). ``scripts/vm/synapse-federation-allowlist.sh --from-state``
consumes it to render the Synapse conf.d snippet. The legacy family policy
``trusted_domains`` list stays in sync (the Synapse spam-checker module and
``family-sync-federation.sh`` still read it).
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Pattern

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from tinywebstack_dashboard.auth import DashboardConfig, require_parent, username_from_headers
from tinywebstack_dashboard.policy_store import load_policy, save_policy

# Hostname labels plus optional :port (Synapse federation whitelists are servers, not URLs).
DOMAIN_RE: Pattern[str] = re.compile(
    r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9]))*(?::[0-9]{1,5})?$"
)

DEFAULT_STATE_PATH = "/etc/tinywebstack/federation-state.json"
DEFAULT_NODES_CONF = "config/nodes.conf"


class InvalidDomain(ValueError):
    """Raised when a domain fails validation."""


def normalize_domain(raw: Any) -> str:
    """Trim and validate a domain[:port]; reject anything that is not a bare hostname."""
    domain = str(raw or "").strip().lower()
    if not domain or not DOMAIN_RE.match(domain):
        raise InvalidDomain(f"invalid domain: {raw!r}")
    if ".." in domain or domain.startswith(".") or domain.endswith("."):
        raise InvalidDomain(f"invalid domain: {raw!r}")
    return domain


def state_path_from_env(default: str = DEFAULT_STATE_PATH) -> Path:
    return Path(os.environ.get("TWS_FEDERATION_STATE_PATH", default))


def _empty_state() -> Dict[str, Any]:
    return {"version": 1, "updated_at": "", "trusted_domains": []}


def load_state(path: Path) -> Dict[str, Any]:
    if not path.is_file():
        return _empty_state()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("federation state must be a JSON object")
    domains = data.get("trusted_domains")
    if not isinstance(domains, list):
        data["trusted_domains"] = []
    return data


def save_state(path: Path, domains: List[str]) -> Dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    state = {
        "version": 1,
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "trusted_domains": sorted(set(domains)),
    }
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".federation-state.", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(state, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return state


def append_domain(path: Path, domain: str) -> None:
    """Idempotently merge a domain into the state file (policy-sync side effect)."""
    state = load_state(path)
    domains = [str(d) for d in state.get("trusted_domains") or []]
    if domain not in domains:
        save_state(path, [*domains, domain])


def synapse_snippet(domains: List[str], ip_range: str = "192.168.122.0/24") -> str:
    """Render the /etc/matrix-synapse/conf.d snippet body (CA lines are appended VM-side)."""
    lines = ["# Managed by tinywebStack", "federation_domain_whitelist:"]
    for d in sorted(set(domains)):
        lines.append(f'  - "{d}"')
    lines.append("ip_range_whitelist:")
    lines.append(f'  - "{ip_range}"')
    return "\n".join(lines) + "\n"


def read_nodes_conf(path: Path) -> List[Dict[str, str]]:
    """Parse NAME DOMAIN RAM VCPUS DISK rows, skipping comments/blanks."""
    if not path.is_file():
        return []
    nodes: List[Dict[str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        nodes.append({"name": parts[0], "domain": parts[1]})
    return nodes


class DomainBody(BaseModel):
    domain: str


def _parent_dep(cfg: DashboardConfig) -> Callable[..., str]:
    def current_user(request: Request) -> str:
        user = username_from_headers(dict(request.headers))
        require_parent(user, cfg)
        return user  # type: ignore[return-value]

    return current_user


def create_router(
    cfg: DashboardConfig,
    *,
    state_path: Optional[Path] = None,
    nodes_conf: Optional[Path] = None,
    on_change: Optional[Callable[[], None]] = None,
) -> APIRouter:
    """Auth-gated trusted-domain endpoints, mounted from create_app()."""
    router = APIRouter()
    auth = _parent_dep(cfg)
    state_file = Path(state_path) if state_path else state_path_from_env()
    nodes_file = Path(
        nodes_conf if nodes_conf else os.environ.get("TW_NODES_CONF", DEFAULT_NODES_CONF)
    )
    policy_file = Path(cfg.policy_path)

    def sync_policy(domains: List[str]) -> None:
        """Mirror the state file into the legacy family-policy trusted_domains list."""
        policy = load_policy(policy_file)
        if sorted(set(policy.get("trusted_domains") or [])) != sorted(set(domains)):
            policy["trusted_domains"] = sorted(set(domains))
            save_policy(policy_file, policy)

    @router.get("/federation/domains", dependencies=[Depends(auth)])
    async def list_domains() -> Dict[str, Any]:
        state = load_state(state_file)
        domains = [str(d) for d in state.get("trusted_domains") or []]
        peer_nodes = [n for n in read_nodes_conf(nodes_file) if n["domain"] != cfg.server_name]
        return {
            "trusted_domains": sorted(set(domains)),
            "peer_nodes": peer_nodes,
            "state_path": str(state_file),
            "updated_at": state.get("updated_at", ""),
        }

    @router.post("/federation/domains", dependencies=[Depends(auth)])
    async def add_domain(body: DomainBody) -> Dict[str, Any]:
        try:
            domain = normalize_domain(body.domain)
        except InvalidDomain as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        if domain == cfg.server_name:
            raise HTTPException(status_code=400, detail="Your own domain is always trusted")
        state = load_state(state_file)
        domains = [str(d) for d in state.get("trusted_domains") or []]
        created = domain not in domains
        if created:
            save_state(state_file, [*domains, domain])
            sync_policy([*domains, domain])
        if on_change:
            on_change()
        return {"ok": True, "domain": domain, "created": created}

    @router.delete("/federation/domains/{domain}", dependencies=[Depends(auth)])
    async def remove_domain(domain: str) -> Dict[str, Any]:
        try:
            domain = normalize_domain(domain)
        except InvalidDomain as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        if domain == cfg.server_name:
            raise HTTPException(status_code=409, detail="Cannot remove your own domain")
        state = load_state(state_file)
        domains = [str(d) for d in state.get("trusted_domains") or []]
        if domain not in domains:
            raise HTTPException(status_code=404, detail=f"Domain not trusted: {domain}")
        remaining = [d for d in domains if d != domain]
        save_state(state_file, remaining)
        sync_policy(remaining)
        if on_change:
            on_change()
        return {"ok": True, "removed": domain}

    return router
