"""Synapse ModuleApi integration for family policy enforcement."""

from __future__ import annotations

import logging
from typing import Any, Callable, List, Optional, Tuple, Union

from tinywebstack_family.policy import FamilyPolicy, PolicyStore

log = logging.getLogger(__name__)

# Synapse provides these at runtime; tests inject mocks.
NOT_SPAM: Any = object()
DenyResult = Union[Any, Tuple[str, dict]]


class FamilySpamCheckerModule:
    """Register spam-checker and third-party-rules callbacks for family policy."""

    def __init__(self, config: dict, api: Any) -> None:
        self.api = api
        global NOT_SPAM
        NOT_SPAM = api.NOT_SPAM

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
        return ("M_FORBIDDEN", {"msg": msg})

    def _policy(self) -> FamilyPolicy:
        p = self.store.policy
        if self.reject_encryption:
            p.reject_encryption = True
        return p

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
        return NOT_SPAM

    async def user_may_join_room(
        self,
        user: str,
        room_id: str,
        is_invited: bool,
    ) -> DenyResult:
        policy = self._policy()
        if not policy.is_kid(user):
            return NOT_SPAM
        if policy.kid_in_quiet_hours(user):
            return self._deny("Quiet hours: kid may not join rooms")
        # Fail closed when policy invalid.
        if policy.fail_closed_kids:
            return self._deny("Family policy unavailable")
        # Invited joins: inviter must be allowlisted (checked via room state when possible).
        members = await self._room_member_mxids(room_id)
        if members:
            for member in members:
                if member == user:
                    continue
                if not policy.contact_allowed_between(user, member):
                    return self._deny("Room member not on kid allowlist")
        return NOT_SPAM

    async def user_may_create_room(
        self,
        user: str,
        is_direct: bool,
    ) -> DenyResult:
        policy = self._policy()
        if not policy.is_kid(user):
            return NOT_SPAM
        if policy.kid_in_quiet_hours(user):
            return self._deny("Quiet hours: kid may not create rooms")
        if not is_direct:
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
        if policy.is_kid(sender):
            room_id = getattr(event, "room_id", None) or event.get("room_id")
            members = await self._room_member_mxids(room_id) if room_id else []
            for member in members:
                if member == sender:
                    continue
                if not policy.contact_allowed_between(sender, member):
                    return self._deny("Message room contains non-allowlisted member")
        return NOT_SPAM

    async def check_event_allowed(
        self,
        event: Any,
        state_events: Any,
    ) -> DenyResult:
        policy = self._policy()
        if not policy.reject_encryption:
            return NOT_SPAM
        ev_type = getattr(event, "type", None) or event.get("type")
        if ev_type != "m.room.encryption":
            return NOT_SPAM
        sender = getattr(event, "sender", None) or event.get("sender")
        if policy.is_kid(sender) or policy.fail_closed_kids:
            return self._deny("End-to-end encryption is disabled for family rooms")
        if self.reject_encryption:
            return self._deny("End-to-end encryption is disabled on this server")
        return NOT_SPAM

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
        for ev in room or []:
            ev_type = getattr(ev, "type", None) or (ev.get("type") if isinstance(ev, dict) else None)
            if ev_type != "m.room.member":
                continue
            state_key = getattr(ev, "state_key", None) or ev.get("state_key")
            content = getattr(ev, "content", None) or ev.get("content") or {}
            membership = content.get("membership") if isinstance(content, dict) else None
            if membership in ("join", "invite") and state_key:
                members.append(state_key)
        return members
