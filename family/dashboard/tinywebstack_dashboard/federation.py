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

log = __import__("logging").getLogger(__name__)

# Hostname labels plus optional :port (Synapse federation whitelists are servers, not URLs).
DOMAIN_RE: Pattern[str] = re.compile(
    r"^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])"
    r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9]))*(?::[0-9]{1,5})?$"
)

DEFAULT_STATE_PATH = "/etc/tinywebstack/federation-state.json"
DEFAULT_NODES_CONF = "config/nodes.conf"


def resolve_nodes_conf_path(explicit: Optional[Path] = None) -> Path:
    """Locate nodes.conf on the VM or in a checkout."""
    if explicit is not None and explicit.is_file():
        return explicit
    env = os.environ.get("TW_NODES_CONF", "").strip()
    if env and Path(env).is_file():
        return Path(env)
    for candidate in (
        Path("/opt/tinywebstack/config/nodes.conf"),
        Path("config/nodes.conf"),
    ):
        if candidate.is_file():
            return candidate
    return Path(explicit or env or DEFAULT_NODES_CONF)


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


def _domain_list(raw: Any) -> List[str]:
    if not isinstance(raw, list):
        return []
    return [str(d).strip() for d in raw if str(d).strip()]


def merged_trusted_domains(
    state_domains: List[str],
    policy_domains: List[str],
    *,
    server_name: str = "",
) -> List[str]:
    """Union of dashboard state and legacy policy (L2.2 migration)."""
    merged: set[str] = set()
    for raw in state_domains + policy_domains:
        if not str(raw).strip():
            continue
        try:
            merged.add(normalize_domain(raw))
        except InvalidDomain:
            log.warning("Skipping invalid trusted domain in federation state/policy: %r", raw)
    if server_name:
        try:
            merged.discard(normalize_domain(server_name))
        except InvalidDomain:
            pass
    return sorted(merged)


def domains_from_synapse_whitelist(path: Path = Path("/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml")) -> List[str]:
    """Best-effort read of existing Synapse federation_domain_whitelist."""
    try:
        if not path.is_file():
            return []
    except OSError as exc:
        log.debug("Cannot access Synapse federation snippet %s: %s", path, exc)
        return []
    try:
        import yaml  # type: ignore

        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as exc:  # pragma: no cover - optional PyYAML on nodes
        log.warning("Could not parse Synapse federation snippet %s: %s", path, exc)
        return []
    raw = doc.get("federation_domain_whitelist")
    if not isinstance(raw, list):
        return []
    return [str(d) for d in raw if str(d).strip()]


def reconcile_state_with_policy(
    state_path: Path,
    policy_path: Path,
    *,
    server_name: str,
    synapse_snippet_path: Optional[Path] = None,
    include_synapse_snippet: bool = True,
) -> List[str]:
    """Ensure federation-state.json and family-policy trusted_domains stay in sync."""
    state = load_state(state_path)
    state_domains = _domain_list(state.get("trusted_domains"))
    policy_domains: List[str] = []
    if policy_path.is_file():
        policy = load_policy(policy_path)
        policy_domains = _domain_list(policy.get("trusted_domains"))
    synapse_domains: List[str] = []
    if include_synapse_snippet:
        snippet_path = synapse_snippet_path or Path(
            "/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml"
        )
        synapse_domains = domains_from_synapse_whitelist(snippet_path)
    merged = merged_trusted_domains(
        state_domains + synapse_domains,
        policy_domains,
        server_name=server_name,
    )
    if merged != sorted(set(state_domains)):
        save_state(state_path, merged)
    if policy_path.is_file():
        policy = load_policy(policy_path)
        if sorted(set(_domain_list(policy.get("trusted_domains")))) != merged:
            policy["trusted_domains"] = merged
            save_policy(policy_path, policy)
    return merged


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
        try:
            os.chmod(path, 0o660)
        except OSError:
            pass
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
    nodes_file = resolve_nodes_conf_path(Path(nodes_conf) if nodes_conf else None)
    policy_file = Path(cfg.policy_path)

    def sync_policy(domains: List[str]) -> None:
        """Mirror the state file into the legacy family-policy trusted_domains list."""
        policy = load_policy(policy_file)
        if sorted(set(policy.get("trusted_domains") or [])) != sorted(set(domains)):
            policy["trusted_domains"] = sorted(set(domains))
            save_policy(policy_file, policy)

    def _effective_domains() -> List[str]:
        return reconcile_state_with_policy(
            state_file,
            policy_file,
            server_name=cfg.server_name,
            include_synapse_snippet=False,
        )

    @router.get("/federation/domains", dependencies=[Depends(auth)])
    async def list_domains() -> Dict[str, Any]:
        state = load_state(state_file)
        domains = _effective_domains()
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
        domains = _effective_domains()
        created = domain not in domains
        if created:
            merged = sorted(set([*domains, domain]))
            save_state(state_file, merged)
            sync_policy(merged)
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
        domains = _effective_domains()
        if domain not in domains:
            raise HTTPException(status_code=404, detail=f"Domain not trusted: {domain}")
        remaining = [d for d in domains if d != domain]
        save_state(state_file, remaining)
        sync_policy(remaining)
        if on_change:
            on_change()
        return {"ok": True, "removed": domain}

    return router
