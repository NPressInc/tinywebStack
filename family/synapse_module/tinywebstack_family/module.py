"""Synapse ModuleApi integration for family policy enforcement."""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional, Tuple, Union

from tinywebstack_family.policy import FamilyPolicy, PolicyStore

log = logging.getLogger(__name__)

try:
    from synapse.module_api import NOT_SPAM
except ImportError:  # unit tests without Synapse
    NOT_SPAM = object()  # type: ignore[misc, assignment]

try:
    from synapse.api.errors import Codes
except ImportError:
    Codes = None  # type: ignore[misc, assignment]

EventAllowResult = Tuple[bool, Optional[dict]]
DenyResult = Union[Any, Tuple[str, dict]]


class FamilySpamCheckerModule:
    """Register spam-checker and third-party-rules callbacks for family policy."""

    def __init__(self, config: dict, api: Any) -> None:
        self.api = api

        policy_path = config.get("policy_path", "/etc/tinywebstack/family-policy.json")
        self.store = PolicyStore(policy_path)
        self.reject_encryption = bool(config.get("reject_encryption", True))

        api.register_spam_checker_callbacks(
            user_may_invite=self.user_may_invite,
            user_may_join_room=self.user_may_join_room,
            user_may_create_room=self.user_may_create_room,
            user_may_send_3pid_invite=self.user_may_send_3pid_invite,
            user_may_publish_room=self.user_may_publish_room,
            check_event_for_spam=self.check_event_for_spam,
        )
        if hasattr(api, "register_third_party_rules_callbacks"):
            api.register_third_party_rules_callbacks(
                check_event_allowed=self.check_event_allowed,
            )

    @staticmethod
    def parse_config(config: dict) -> dict:
        return config

    def _deny(self, msg: str) -> DenyResult:
        log.info("Family policy deny: %s", msg)
        code = Codes.FORBIDDEN if Codes is not None else "M_FORBIDDEN"
        return (code, {"msg": msg})

    def _policy(self) -> FamilyPolicy:
        p = self.store.policy
        if self.reject_encryption:
            p.reject_encryption = True
        return p

    def _room_is_direct(self, room_config: Any) -> bool:
        if isinstance(room_config, dict):
            if room_config.get("is_direct"):
                return True
            preset = room_config.get("preset") or room_config.get("creation_content", {}).get(
                "preset"
            )
            if preset in ("trusted_private_chat", "private_chat"):
                return True
        if isinstance(room_config, bool):
            return room_config
        return False

    async def _kids_in_room(self, policy: FamilyPolicy, member_mxids: List[str]) -> List[str]:
        return [m for m in member_mxids if policy.is_kid(m)]

    async def _room_ok_for_kids(
        self, policy: FamilyPolicy, member_mxids: List[str], extra: Optional[str] = None
    ) -> bool:
        prospective = list(member_mxids)
        if extra:
            prospective.append(extra)
        kids = await self._kids_in_room(policy, prospective)
        if not kids:
            return True
        for kid in kids:
            for member in prospective:
                if member == kid:
                    continue
                if not policy.contact_allowed_between(kid, member):
                    return False
        return True

    async def user_may_invite(
        self,
        inviter: str,
        invitee: str,
        room_id: str,
    ) -> DenyResult:
        policy = self._policy()
        if policy.is_kid(inviter) and policy.kid_in_quiet_hours(inviter):
            return self._deny("Quiet hours: kid may not send invites")
        if not policy.contact_allowed_between(inviter, invitee):
            return self._deny("Contact not on kid allowlist")
        members = await self._room_member_mxids(room_id)
        if not await self._room_ok_for_kids(policy, members, extra=invitee):
            return self._deny("Invite would add a non-allowlisted user to a child's room")
        return NOT_SPAM

    async def user_may_join_room(
        self,
        user: str,
        room_id: str,
        is_invited: bool,
    ) -> DenyResult:
        policy = self._policy()
        if policy.is_kid(user):
            if policy.kid_in_quiet_hours(user):
                return self._deny("Quiet hours: kid may not join rooms")
            if policy.fail_closed_kids:
                return self._deny("Family policy unavailable")
        members = await self._room_member_mxids(room_id)
        if policy.is_kid(user):
            if not await self._room_ok_for_kids(policy, members, extra=user):
                return self._deny("Room member not on kid allowlist")
        elif not await self._room_ok_for_kids(policy, members, extra=user):
            return self._deny("Join would add a non-allowlisted user to a child's room")
        return NOT_SPAM

    async def user_may_create_room(
        self,
        user: str,
        room_config: Any,
    ) -> DenyResult:
        policy = self._policy()
        if not policy.is_kid(user):
            return NOT_SPAM
        if policy.kid_in_quiet_hours(user):
            return self._deny("Quiet hours: kid may not create rooms")
        if not self._room_is_direct(room_config):
            return self._deny("Kids may not create group rooms")
        return NOT_SPAM

    async def user_may_send_3pid_invite(
        self,
        user: str,
        medium: str,
        address: str,
        room_id: str,
    ) -> DenyResult:
        policy = self._policy()
        if policy.is_kid(user):
            return self._deny("Kids may not send email/phone invites")
        return NOT_SPAM

    async def user_may_publish_room(self, user: str, room_id: str) -> DenyResult:
        policy = self._policy()
        if policy.is_kid(user):
            return self._deny("Kids may not publish rooms to the directory")
        return NOT_SPAM

    async def check_event_for_spam(self, event: Any) -> DenyResult:
        policy = self._policy()
        sender = getattr(event, "sender", None) or event.get("sender")
        if not sender:
            return NOT_SPAM
        if policy.is_kid(sender) and policy.kid_in_quiet_hours(sender):
            return self._deny("Quiet hours: kid may not send messages")
        room_id = getattr(event, "room_id", None) or event.get("room_id")
        members = await self._room_member_mxids(room_id) if room_id else []
        if policy.is_kid(sender):
            if not await self._room_ok_for_kids(policy, members):
                return self._deny("Message room contains non-allowlisted member")
        elif not await self._room_ok_for_kids(policy, members):
            return self._deny("Message room contains non-allowlisted member for a child")
        return NOT_SPAM

    async def check_event_allowed(
        self,
        event: Any,
        state_events: Any,
    ) -> EventAllowResult:
        policy = self._policy()
        if not policy.reject_encryption:
            return True, None
        ev_type = getattr(event, "type", None) or event.get("type")
        if ev_type != "m.room.encryption":
            return True, None
        sender = getattr(event, "sender", None) or event.get("sender")
        if policy.is_kid(sender) or policy.fail_closed_kids:
            return False, {"msg": "End-to-end encryption is disabled for family rooms"}
        if self.reject_encryption:
            return False, {"msg": "End-to-end encryption is disabled on this server"}
        return True, None

    def _member_from_state_event(self, ev: Any) -> Optional[str]:
        ev_type = getattr(ev, "type", None)
        if ev_type is None and isinstance(ev, dict):
            ev_type = ev.get("type")
        if ev_type != "m.room.member":
            return None
        state_key = getattr(ev, "state_key", None) or (ev.get("state_key") if isinstance(ev, dict) else None)
        content = getattr(ev, "content", None) or (ev.get("content") if isinstance(ev, dict) else {}) or {}
        membership = content.get("membership") if isinstance(content, dict) else None
        if membership in ("join", "invite") and state_key:
            return state_key
        return None

    async def _room_member_mxids(self, room_id: str) -> List[str]:
        if not room_id:
            return []
        try:
            room = await self.api.get_room_state(room_id)
        except Exception:
            try:
                room = await self.api.get_state_events_in_room(room_id, "")
            except Exception:
                return []
        members: List[str] = []
        if room is None:
            return members
        if hasattr(room, "values"):
            events = room.values()
        elif isinstance(room, dict):
            events = room.values()
        else:
            events = room
        for ev in events:
            mxid = self._member_from_state_event(ev)
            if mxid:
                members.append(mxid)
        return members
