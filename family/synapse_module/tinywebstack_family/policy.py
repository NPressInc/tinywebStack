"""Family policy loading and pure policy checks (no Synapse dependency)."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple
from zoneinfo import ZoneInfo

log = logging.getLogger(__name__)


def parse_mxid(mxid: str) -> Tuple[str, str]:
    """Return (localpart, domain) for @local:domain."""
    if not mxid.startswith("@") or ":" not in mxid:
        raise ValueError(f"Invalid MXID: {mxid!r}")
    local, domain = mxid[1:].split(":", 1)
    return local, domain


@dataclass
class QuietHours:
    start: str  # HH:MM
    end: str
    timezone: str
    days: List[int] = field(default_factory=lambda: list(range(7)))

    def is_active(self, when: Optional[datetime] = None) -> bool:
        when = when or datetime.now(tz=ZoneInfo("UTC"))
        try:
            tz = ZoneInfo(self.timezone)
        except Exception:
            log.warning("Invalid quiet-hours timezone %r", self.timezone)
            return False
        local = when.astimezone(tz)
        if local.weekday() not in self.days:
            return False
        start_h, start_m = (int(x) for x in self.start.split(":", 1))
        end_h, end_m = (int(x) for x in self.end.split(":", 1))
        start_t = time(start_h, start_m)
        end_t = time(end_h, end_m)
        now_t = local.time()
        if start_t <= end_t:
            return start_t <= now_t < end_t
        # Window wraps midnight (e.g. 21:00–07:00).
        return now_t >= start_t or now_t < end_t


@dataclass
class KidPolicy:
    mxid: str
    allowlist_mxids: Set[str] = field(default_factory=set)
    allowlist_domains: Set[str] = field(default_factory=set)
    quiet_hours: Optional[QuietHours] = None


@dataclass
class FamilyPolicy:
    server_name: str
    kids: Dict[str, KidPolicy]
    parent_mxids: Set[str]
    trusted_domains: Set[str]
    reject_encryption: bool
    valid: bool = True
    fail_closed_kids: bool = False

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "FamilyPolicy":
        server = str(data.get("server_name", "")).strip()
        reject_enc = bool(data.get("reject_encryption", True))
        parents = {str(x).strip() for x in data.get("parent_mxids", []) if x}
        trusted = {str(x).strip() for x in data.get("trusted_domains", []) if x}
        kids_raw = data.get("kids") or {}
        kids: Dict[str, KidPolicy] = {}
        for mxid, cfg in kids_raw.items():
            if not isinstance(cfg, dict):
                continue
            mxid = str(mxid).strip()
            allow_mx = {str(x).strip() for x in cfg.get("allowlist_mxids", []) if x}
            allow_dom = {str(x).strip() for x in cfg.get("allowlist_domains", []) if x}
            qh = None
            qh_raw = cfg.get("quiet_hours")
            if isinstance(qh_raw, dict) and qh_raw.get("start") and qh_raw.get("end"):
                qh = QuietHours(
                    start=str(qh_raw["start"]),
                    end=str(qh_raw["end"]),
                    timezone=str(qh_raw.get("timezone", "UTC")),
                    days=[int(d) for d in qh_raw.get("days", list(range(7)))],
                )
            kids[mxid] = KidPolicy(
                mxid=mxid,
                allowlist_mxids=allow_mx,
                allowlist_domains=allow_dom,
                quiet_hours=qh,
            )
        return cls(
            server_name=server,
            kids=kids,
            parent_mxids=parents,
            trusted_domains=trusted,
            reject_encryption=reject_enc,
            valid=True,
        )

    @classmethod
    def fail_closed(cls, server_name: str = "") -> "FamilyPolicy":
        return cls(
            server_name=server_name,
            kids={},
            parent_mxids=set(),
            trusted_domains=set(),
            reject_encryption=True,
            valid=False,
            fail_closed_kids=True,
        )

    def is_kid(self, mxid: str) -> bool:
        return mxid in self.kids

    def is_parent(self, mxid: str) -> bool:
        return mxid in self.parent_mxids

    def kid_policy(self, mxid: str) -> Optional[KidPolicy]:
        return self.kids.get(mxid)

    def is_local_user(self, mxid: str) -> bool:
        try:
            _, domain = parse_mxid(mxid)
        except ValueError:
            return False
        return domain == self.server_name

    def is_allowlisted_contact(self, mxid: str, for_kid: KidPolicy) -> bool:
        if mxid == for_kid.mxid:
            return True
        if mxid in for_kid.allowlist_mxids:
            return True
        if self.is_parent(mxid) and self.is_local_user(mxid):
            return True
        try:
            _, domain = parse_mxid(mxid)
        except ValueError:
            return False
        if domain in for_kid.allowlist_domains:
            return True
        if domain in self.trusted_domains and mxid in for_kid.allowlist_mxids:
            return True
        return False

    def contact_allowed_between(self, a: str, b: str) -> bool:
        """Both directions when either party is a kid."""
        if self.fail_closed_kids:
            if self.is_parent(a) and self.is_parent(b):
                return True
            return False
        if self.is_parent(a) or self.is_parent(b):
            return True
        ka = self.kid_policy(a)
        kb = self.kid_policy(b)
        if ka and not self.is_allowlisted_contact(b, ka):
            return False
        if kb and not self.is_allowlisted_contact(a, kb):
            return False
        return True

    def kid_in_quiet_hours(self, kid_mxid: str, when: Optional[datetime] = None) -> bool:
        kp = self.kid_policy(kid_mxid)
        if not kp or not kp.quiet_hours:
            return False
        return kp.quiet_hours.is_active(when)


class PolicyStore:
    """Load /etc/tinywebstack/family-policy.json with mtime-based reload."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._stamp: tuple[int, int] = (0, 0)
        self._policy: FamilyPolicy = FamilyPolicy.fail_closed()

    @property
    def policy(self) -> FamilyPolicy:
        self.reload_if_changed()
        return self._policy

    def reload_if_changed(self) -> None:
        if not self.path.is_file():
            if not self._policy.fail_closed_kids:
                log.error("Family policy missing at %s — failing closed for kids", self.path)
            self._policy = FamilyPolicy.fail_closed()
            self._stamp = (0, 0)
            return
        try:
            st = self.path.stat()
        except OSError as exc:
            log.error("Cannot stat family policy %s: %s", self.path, exc)
            self._policy = FamilyPolicy.fail_closed()
            return
        stamp = (int(st.st_mtime_ns), int(st.st_size))
        if stamp == self._stamp:
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("policy root must be an object")
            self._policy = FamilyPolicy.from_dict(raw)
            self._stamp = stamp
            log.info("Loaded family policy from %s (%d kids)", self.path, len(self._policy.kids))
        except Exception as exc:
            log.error("Invalid family policy at %s: %s — failing closed for kids", self.path, exc)
            self._policy = FamilyPolicy.fail_closed()
            self._stamp = stamp


def policy_to_dict(policy: FamilyPolicy) -> Dict[str, Any]:
    kids: Dict[str, Any] = {}
    for mxid, kp in policy.kids.items():
        entry: Dict[str, Any] = {
            "allowlist_mxids": sorted(kp.allowlist_mxids),
            "allowlist_domains": sorted(kp.allowlist_domains),
        }
        if kp.quiet_hours:
            entry["quiet_hours"] = {
                "start": kp.quiet_hours.start,
                "end": kp.quiet_hours.end,
                "timezone": kp.quiet_hours.timezone,
                "days": kp.quiet_hours.days,
            }
        kids[mxid] = entry
    return {
        "server_name": policy.server_name,
        "parent_mxids": sorted(policy.parent_mxids),
        "trusted_domains": sorted(policy.trusted_domains),
        "reject_encryption": policy.reject_encryption,
        "kids": kids,
    }


def write_policy_atomic(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)

def empty_policy(server_name: str) -> Dict[str, Any]:
    return {
        "server_name": server_name,
        "parent_mxids": [],
        "trusted_domains": [],
        "reject_encryption": True,
        "kids": {},
    }
