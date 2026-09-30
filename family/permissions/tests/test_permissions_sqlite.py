"""F1.3 SQLite permission store — integration tests on REAL sqlite (tmp_path DB).

Covers: seeded role verdicts == old hardcoded rules (spam checker through the
real code path), dashboard→DB→spam-checker end-to-end flip, tamper rejection,
DB-missing fallback to legacy JSON policy, and seed idempotency / export.
"""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tinywebstack_permissions.store import (
    PermissionsDB,
    QuietHours,
    default_role_seed_files,
    get_db_path,
)

SERVER = "family-a.test"
PARENT = f"@parent:{SERVER}"
KID = f"@kid:{SERVER}"
FRIEND = "@friend:family-b.test"
STRANGER = "@stranger:evil.test"

ROLE_FILES = [str(p) for p in default_role_seed_files()]


class MockMemberEvent:
    def __init__(self, mxid: str, membership: str = "join"):
        self.type = "m.room.member"
        self.state_key = mxid
        self.content = {"membership": membership}


class MockApi:
    def __init__(self, members=None):
        self.members = members or {}
        self.registered: dict = {}

    def register_spam_checker_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    def register_third_party_rules_callbacks(self, **kwargs):
        self.registered.update(kwargs)

    async def get_room_state(self, room_id):
        return self.members


def _seeded_db(path: Path) -> PermissionsDB:
    db = PermissionsDB(path)
    db.seed_roles(ROLE_FILES)
    db.set_server_name(SERVER)
    db.set_role(PARENT, "parent")
    db.set_role(KID, "kid")
    return db


def _legacy_policy_dict() -> dict:
    """The pre-F1.3 lab configuration (what family-policy.json encoded)."""
    return {
        "server_name": SERVER,
        "parent_mxids": [PARENT],
        "trusted_domains": ["family-b.test"],
        "reject_encryption": True,
        "kids": {
            KID: {
                "allowlist_mxids": [FRIEND],
                "allowlist_domains": [],
                "events_enabled": True,
            }
        },
    }


def _make_module(policy_file, db_file=None):
    from tinywebstack_family.module import FamilySpamCheckerModule

    config = {"policy_path": str(policy_file), "reject_encryption": True}
    if db_file is not None:
        config["permissions_db"] = str(db_file)
    api = MockApi(members={})
    mod = FamilySpamCheckerModule(config, api)
    return mod, api


# ------------------------------------------------------------------ schema / seed


def test_schema_and_seed_version(tmp_path):
    db = _seeded_db(tmp_path / "permissions.db")
    with db:
        assert db.get_meta("schema_version") == 1
        assert db.server_name == SERVER
        assert sorted(db.users_with_role("kid")) == [KID]
        assert sorted(db.users_with_role("parent")) == [PARENT]
        assert db.role_is_admin("parent") is True
        assert db.role_is_admin("kid") is False


def test_role_yaml_seed_matches_hardcoded_rules(tmp_path):
    """Default seeded parent/kid rows == old hardcoded spam-checker rules."""
    db = _seeded_db(tmp_path / "permissions.db")
    kid = db.get_permissions("kid")
    parent = db.get_permissions("parent")
    db.close()
    assert kid is not None and parent is not None
    assert kid.role == "kid" and not kid.is_admin
    assert kid.can_create_rooms is True          # direct chats allowed
    assert kid.can_create_group_rooms is False   # hardcoded rule
    assert kid.can_send_3pid_invites is False    # hardcoded rule
    assert kid.can_publish_rooms is False        # hardcoded rule
    assert kid.mobilizon_role == "member"
    assert kid.quiet_hours is None
    assert parent.role == "parent" and parent.is_admin
    assert parent.can_create_rooms and parent.can_create_group_rooms
    assert parent.can_send_3pid_invites and parent.can_publish_rooms
    assert parent.mobilizon_role == "admin"


def test_seed_idempotent(tmp_path):
    path = tmp_path / "permissions.db"
    first = _seeded_db(path)
    first.set_permission(KID, "allowlist_mxids", [FRIEND])
    first.close()
    again = PermissionsDB(path)
    again.seed_roles(ROLE_FILES)  # re-run of the seed step
    ps = again.get_permissions(KID)
    again.close()
    assert ps is not None
    assert FRIEND in ps.allowlist_mxids  # per-user override survives role re-seed


def test_set_revoke_roundtrip(tmp_path):
    db = _seeded_db(tmp_path / "permissions.db")
    db.set_permission(KID, "quiet_hours", {
        "start": "21:00", "end": "07:00", "timezone": "UTC", "days": [0, 1, 2, 3, 4],
    })
    ps = db.get_permissions(KID)
    assert ps and ps.quiet_hours and ps.quiet_hours.start == "21:00"
    assert ps.quiet_hours.days == [0, 1, 2, 3, 4]
    db.revoke_permission(KID, "quiet_hours")
    ps = db.get_permissions(KID)
    assert ps and ps.quiet_hours is None  # back to role default
    db.close()


def test_export_import_roundtrip(tmp_path):
    src = _seeded_db(tmp_path / "a.db")
    src.set_permission(KID, "allowlist_mxids", [FRIEND])
    dump = src.export_dict()
    src.close()
    dst = PermissionsDB(tmp_path / "b.db")
    dst.import_dict(json.loads(json.dumps(dump)))
    ps = dst.get_permissions("kid")
    dst.close()
    assert ps is not None
    assert ps.allowlist_mxids == {FRIEND}
    assert ps.role == "kid"


def test_env_override_and_default_path(tmp_path, monkeypatch):
    monkeypatch.setenv("TWS_PERMISSIONS_DB", str(tmp_path / "env.db"))
    assert get_db_path() == tmp_path / "env.db"
    monkeypatch.delenv("TWS_PERMISSIONS_DB")
    assert get_db_path() == Path("/etc/tinywebstack/permissions.db")


def test_quiet_hours_active_window_now():
    now = datetime.now(tz=timezone.utc)
    start = (now - timedelta(hours=1)).strftime("%H:%M")
    end = (now + timedelta(hours=1)).strftime("%H:%M")
    qh = QuietHours(start=start, end=end, timezone="UTC")
    assert qh.is_active(now)


# ------------------------------------------------- spam checker: DB-backed verdicts


@pytest.fixture
def legacy(tmp_path):
    policy_file = tmp_path / "family-policy.json"
    policy_file.write_text(json.dumps(_legacy_policy_dict()), encoding="utf-8")
    return policy_file


def test_db_verdicts_match_legacy_json_verdicts(tmp_path, legacy):
    """Every callback verdict identical between JSON store (old path) and DB."""
    from tinywebstack_family.module import NOT_SPAM

    db_file = tmp_path / "permissions.db"
    db = PermissionsDB(db_file)
    db.seed_roles(ROLE_FILES)
    db.import_legacy_policy(_legacy_policy_dict())
    db.close()

    mod_json, api_json = _make_module(legacy, db_file=None)
    mod_db, api_db = _make_module(legacy, db_file=db_file)

    async def verdicts(api):
        cb = api.registered
        out = {}
        api.members = {}
        out["invite_friend"] = await cb["user_may_invite"](KID, FRIEND, "!r")
        out["invite_stranger"] = await cb["user_may_invite"](KID, STRANGER, "!r")
        out["parent_invite_friend"] = await cb["user_may_invite"](PARENT, FRIEND, "!r")
        out["kid_join"] = await cb["user_may_join_room"](KID, "!r", True)
        out["adult_join"] = await cb["user_may_join_room"](f"@bob:{SERVER}", "!r", False)
        out["kid_group_room"] = await cb["user_may_create_room"](
            KID, {"preset": "public_chat", "is_direct": False}
        )
        out["kid_direct_room"] = await cb["user_may_create_room"](
            KID, {"is_direct": True, "invite": [FRIEND]}
        )
        out["kid_direct_multi"] = await cb["user_may_create_room"](
            KID, {"is_direct": True, "invite": [FRIEND, STRANGER]}
        )
        out["parent_create_room"] = await cb["user_may_create_room"](PARENT, {})
        out["kid_3pid"] = await cb["user_may_send_3pid_invite"](KID, "email", "x@y.z", "!r")
        out["kid_publish"] = await cb["user_may_publish_room"](KID, "!r")
        out["parent_publish"] = await cb["user_may_publish_room"](PARENT, "!r")
        out["kid_message"] = await cb["check_event_for_spam"](
            {"sender": KID, "room_id": "!r:x", "type": "m.room.message"}
        )
        enc = await cb["check_event_allowed"](
            {"type": "m.room.encryption", "sender": PARENT}, []
        )
        out["encryption"] = (bool(enc[0]),)
        return out

    a = asyncio.run(verdicts(api_json))
    b = asyncio.run(verdicts(api_db))
    assert a == b, "DB-backed verdicts diverged from legacy JSON verdicts"
    # Sanity: the allow/deny split itself matches the old hardcoded behaviour.
    assert a["invite_friend"] is NOT_SPAM
    assert a["invite_stranger"] is not NOT_SPAM
    assert a["kid_group_room"] is not NOT_SPAM
    assert a["kid_direct_room"] is NOT_SPAM
    assert a["kid_direct_multi"] is not NOT_SPAM
    assert a["parent_create_room"] is NOT_SPAM
    assert a["kid_3pid"] is not NOT_SPAM
    assert a["kid_publish"] is not NOT_SPAM
    assert a["parent_publish"] is NOT_SPAM
    assert a["kid_join"] is NOT_SPAM
    assert a["adult_join"] is NOT_SPAM
    assert a["kid_message"] is NOT_SPAM
    assert a["encryption"] == (False,)


def test_db_quiet_hours_blocks_kid(tmp_path, legacy):
    """Quiet hours queried from the DB (wall-clock-free: window straddles now)."""
    from tinywebstack_family.module import NOT_SPAM

    db_file = tmp_path / "permissions.db"
    db = PermissionsDB(db_file)
    db.seed_roles(ROLE_FILES)
    db.import_legacy_policy(_legacy_policy_dict())
    now = datetime.now(tz=timezone.utc)
    db.set_permission(KID, "quiet_hours", {
        "start": (now - timedelta(hours=1)).strftime("%H:%M"),
        "end": (now + timedelta(hours=1)).strftime("%H:%M"),
        "timezone": "UTC",
        "days": list(range(7)),
    })
    db.close()
    mod, api = _make_module(legacy, db_file=db_file)
    cb = api.registered
    result = asyncio.run(cb["check_event_for_spam"](
        {"sender": KID, "room_id": "!r:x", "type": "m.room.message"}
    ))
    assert result is not NOT_SPAM
    result = asyncio.run(cb["user_may_create_room"](KID, {"is_direct": True}))
    assert result is not NOT_SPAM
    result = asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r"))
    assert result is not NOT_SPAM
    # Parent is never quiet-hours gated.
    result = asyncio.run(cb["user_may_publish_room"](PARENT, "!r"))
    assert result is NOT_SPAM


def test_missing_db_falls_back_to_json(tmp_path, legacy):
    """DB-missing = current hardcoded defaults via JSON policy (safe degrade)."""
    from tinywebstack_family.module import NOT_SPAM

    mod, api = _make_module(legacy, db_file=tmp_path / "does-not-exist.db")
    assert type(mod.store).__name__ == "SqliteFamilyPolicyStore"
    cb = api.registered
    result = asyncio.run(cb["user_may_invite"](KID, STRANGER, "!r"))
    assert result is not NOT_SPAM  # still blocked via legacy JSON
    result = asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r"))
    assert result is NOT_SPAM
    result = asyncio.run(cb["user_may_create_room"](KID, {"is_direct": False}))
    assert result is not NOT_SPAM  # group-room ban still enforced


def test_corrupt_db_fails_closed(tmp_path, legacy):
    from tinywebstack_family.module import NOT_SPAM

    db_file = tmp_path / "permissions.db"
    db_file.write_bytes(b"this is not a sqlite file")
    mod, api = _make_module(legacy, db_file=db_file)
    cb = api.registered
    # Kid gated (fail-closed), parent unaffected.
    result = asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r"))
    assert result is not NOT_SPAM
    result = asyncio.run(cb["user_may_publish_room"](PARENT, "!r"))
    assert result is NOT_SPAM


# ------------------------------------ dashboard ↔ DB ↔ spam-checker end-to-end


@pytest.fixture
def dash(tmp_path, monkeypatch):
    """Dashboard TestClient + a live spam-checker module on the SAME DB file."""
    from fastapi.testclient import TestClient
    from tinywebstack_dashboard.app import DashboardConfig, create_app

    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps(
        {"parents": ["parent"], "kids": ["kid"]}
    ))
    monkeypatch.setenv(
        "TWS_DASHBOARD_MOCK_LIST_USERS",
        json.dumps({"users": {"parent": {"groups": ["parents"]},
                              "kid": {"groups": ["kids"]}}}),
    )
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_YUNOHOST", "1")
    db_file = tmp_path / "permissions.db"
    monkeypatch.setenv("TWS_PERMISSIONS_DB", str(db_file))
    policy_file = tmp_path / "family-policy.json"
    policy_file.write_text(
        json.dumps({**_legacy_policy_dict(), "kids": {}}), encoding="utf-8"
    )
    cfg = DashboardConfig(
        policy_path=str(policy_file),
        server_name=SERVER,
        csrf_secret="test-secret",
    )
    client = TestClient(create_app(cfg))
    # Spam checker pointed at the empty-JSON policy + same DB (starts unseeded).
    mod, api = _make_module(policy_file, db_file=db_file)
    return {"client": client, "db_file": db_file, "cb": api.registered,
            "policy_file": policy_file}


def test_dashboard_parent_edit_flips_spam_checker(tmp_path, dash):
    """Parent adds kid to invite allow-list via API → spam checker allows.

    Proves end-to-end wiring through the real code paths (dashboard router
    writes the same SQLite file the module's policy store re-reads), with no
    mocks of the store itself.
    """
    from tinywebstack_family.module import NOT_SPAM

    cb = dash["cb"]
    db_file = dash["db_file"]

    # Simulate the seed step having run: kid exists in the DB, no allow-list.
    db = PermissionsDB(db_file)
    db.seed_roles(ROLE_FILES)
    db.set_server_name(SERVER)
    db.set_role(KID, "kid")
    db.close()

    # Kid is gated via the real module code path → friend invite blocked.
    assert asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r")) is not NOT_SPAM
    assert asyncio.run(cb["user_may_invite"](KID, STRANGER, "!r")) is not NOT_SPAM

    # Parent grants the contact via the dashboard API (same DB file).
    r = dash["client"].put(
        "/permissions/kid",
        headers={"YNH_USER": "parent"},
        json={"allowlist_mxids": [FRIEND]},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["role"] == "kid" and FRIEND in body["allowlist_mxids"]

    # Enforcement flipped for the allowed contact without any restart: the
    # module's policy store re-reads the SQLite file on change.
    assert asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r")) is NOT_SPAM
    assert asyncio.run(cb["user_may_invite"](KID, STRANGER, "!r")) is not NOT_SPAM

    # Revoke the allow-list override → friend blocked again.
    r = dash["client"].put(
        "/permissions/kid",
        headers={"YNH_USER": "parent"},
        json={"revoke": ["allowlist_mxids"]},
    )
    assert r.status_code == 200
    assert asyncio.run(cb["user_may_invite"](KID, FRIEND, "!r")) is not NOT_SPAM


def test_dashboard_get_permissions(dash):
    client = dash["client"]
    r = client.get("/permissions/kid", headers={"YNH_USER": "parent"})
    assert r.status_code == 200
    body = r.json()
    assert body["role"] == "kid"
    assert body["can_publish_rooms"] is False
    assert body["can_create_group_rooms"] is False
    # Kid may view their own, not others'.
    assert client.get(
        "/permissions/kid", headers={"YNH_USER": "kid"}
    ).status_code == 200
    assert client.get(
        "/permissions/parent", headers={"YNH_USER": "kid"}
    ).status_code == 403
    # No SSO header → 401.
    assert client.get("/permissions/kid").status_code == 401


def test_dashboard_kid_cannot_self_promote(dash):
    """Tamper case: non-parent PUT rejected server-side."""
    client, db_file = dash["client"], dash["db_file"]
    # Seed step has run: kid exists with role defaults.
    db = PermissionsDB(db_file)
    db.seed_roles(ROLE_FILES)
    db.set_server_name(SERVER)
    db.set_role(KID, "kid")
    db.close()
    assert client.put(
        "/permissions/kid", headers={"YNH_USER": "kid"},
        json={"can_publish_rooms": True},
    ).status_code == 403
    assert client.put(
        "/permissions/parent", headers={"YNH_USER": "kid"},
        json={"role": "parent"},
    ).status_code == 403
    assert client.put(
        "/permissions/kid", json={"can_publish_rooms": True}
    ).status_code == 401
    # Nothing changed in the DB.
    db = PermissionsDB(db_file)
    ps = db.get_permissions("kid")
    db.close()
    assert ps is not None
    assert ps.can_publish_rooms is False and ps.role == "kid"
    assert ps.is_admin is False


def test_dashboard_unknown_user_and_bad_payload(dash):
    client = dash["client"]
    assert client.put(
        "/permissions/nobody", headers={"YNH_USER": "parent"},
        json={"events_enabled": False},
    ).status_code == 404
    assert client.put(
        "/permissions/kid", headers={"YNH_USER": "parent"},
        json={"is_admin": True},  # unknown field → 422 via extra=forbid
    ).status_code == 422
    assert client.put(
        "/permissions/kid", headers={"YNH_USER": "parent"},
        json={"role": "superuser"},  # unseeded role → 400
    ).status_code == 400


def test_dashboard_events_toggle_visible_to_store(dash):
    client, db_file = dash["client"], dash["db_file"]
    r = client.put(
        "/permissions/kid", headers={"YNH_USER": "parent"},
        json={"events_enabled": False},
    )
    assert r.status_code == 200
    db = PermissionsDB(db_file)
    enabled = db.enabled_event_usernames()
    db.close()
    assert "kid" not in enabled


# ------------------------------------------------------------ seed CLI behaviour


def test_seed_cli(tmp_path, capsys):
    from tinywebstack_permissions.seed_cli import main

    policy = tmp_path / "family-policy.json"
    policy.write_text(json.dumps(_legacy_policy_dict()), encoding="utf-8")
    db = tmp_path / "permissions.db"
    assert main(["seed", "--db", str(db), "--policy", str(policy)]) == 0
    assert main(["seed", "--db", str(db), "--policy", str(policy)]) == 0  # idempotent
    assert main(["show", "kid", "--db", str(db)]) == 0
    store = PermissionsDB(db)
    ps = store.get_permissions("kid")
    dump = store.export_dict()
    store.close()
    assert ps is not None and FRIEND in ps.allowlist_mxids
    assert len(dump["users"]) == 2
    # import-dump restores into a fresh file
    backup = tmp_path / "backup.json"
    backup.write_text(json.dumps(dump), encoding="utf-8")
    fresh = tmp_path / "fresh.db"
    assert main(["import-dump", str(backup), "--db", str(fresh)]) == 0
    store = PermissionsDB(fresh)
    ps = store.get_permissions("kid")
    store.close()
    assert ps is not None and FRIEND in ps.allowlist_mxids


# ------------------------------------------------- Mobilizon helper DB preference


def test_mobilizon_enabled_kids_from_db(tmp_path):
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "apply_mobilizon_permissions",
        Path(__file__).resolve().parents[3]
        / "scripts" / "lib" / "apply_mobilizon_permissions.py",
    )
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    policy = _legacy_policy_dict()
    db_file = tmp_path / "permissions.db"
    db = PermissionsDB(db_file)
    db.seed_roles(ROLE_FILES)
    db.import_legacy_policy(policy)
    db.set_permission(KID, "events_enabled", False)
    db.close()

    # DB (kid events disabled) wins over JSON (enabled).
    assert mod._enabled_kid_usernames(policy, str(db_file)) == set()
    # Missing DB → JSON verdict.
    assert mod._enabled_kid_usernames(policy, str(tmp_path / "nope.db")) == {"kid"}
