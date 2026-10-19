# Family Synapse module

The `tinywebstack_family` Python package registers Synapse **spam checker** callbacks (and **third-party rules** for encryption state) to enforce family policy server-side.

## Install

On a YunoHost VM (after Synapse is installed):

```bash
./scripts/vm/remote-run.sh "$IP" family-init.sh family-a.family.test family-a
```

Or step by step:

```bash
./scripts/vm/remote-run.sh "$IP" install-family-module.sh family-a.family.test
```

This pip-installs the module into the Synapse venv, drops `/etc/matrix-synapse/conf.d/tinywebstack-family.yaml`, sets `encryption_enabled_by_default_for_room_type: all` so new rooms and DMs are E2EE by default, and restarts Synapse.

`install-family-module.sh` also creates `/etc/tinywebstack/matrix-login-ticket.secret` (32 random bytes, mode `640`, group `www-data`) and sets module config `login_ticket_secret_file` to that path. The family dashboard reads the same path via `TWS_MATRIX_LOGIN_TICKET_SECRET_FILE` to mint short-lived tickets for code enrollment.

### Matrix login type `org.tinywebstack.login_ticket`

When `login_ticket_secret_file` (or inline `login_ticket_secret`) is configured, the module registers a Synapse password-auth checker for login type `org.tinywebstack.login_ticket` with field `ticket`. Tickets are HMAC-SHA256 payloads (`v1.<localpart>.<exp>.<nonce>.<sig>`, 60s TTL by default, max 300s). Only the homeserver and dashboard (which never exposes the ticket to clients) use this path: the dashboard POSTs to `/_matrix/client/v3/login` server-side during TinyWeb **code** enrollment so the app receives a normal `access_token` and `device_id`.

## Policy file

Path: `/etc/tinywebstack/family-policy.json` (configurable via module config `policy_path`).

The parent dashboard syncs kid MXIDs from the YunoHost `kids` group and parent MXIDs from `parents`. Group names are overridable with `TWS_KIDS_GROUP` / `TWS_PARENTS_GROUP`.

### End-to-end encryption (Stage 1)

Chat is **end-to-end encrypted by default**. The module still enforces allowlists and quiet hours using **membership, sender MXIDs, and invites** — metadata the homeserver must see to route events. Message **content** is not visible to the server or to parents on the dashboard. Parent-key oversight is deferred; parents read a kid’s encrypted chats only on the kid’s device for now.

Legacy opt-out: set `reject_encryption: true` in policy JSON and/or module config to block `m.room.encryption` state events (not recommended).

### Kid join rule

A kid may **invite** / be **invited** / **join** / **message** only when every other human in the room is:

- on that kid’s MXID allowlist,
- on an allowlisted domain entry for that kid,
- a **local parent** (`parent_mxids` on the same `server_name`), or
- the kid themselves.

Parents (listed in `parent_mxids`) are not subject to kid allowlists. Server admins bypass some Synapse hooks upstream — family **parents should not be Synapse admins**.

Invalid or missing policy → **fail closed** for kids (deny invites/joins/messages).

## Operator testing (TinyWeb app)

Primary check: enroll the **TinyWeb app** as the kid and exercise chat policy in-app (see [TINYWEB_APP_PLAN.md](TINYWEB_APP_PLAN.md) Stage 1 tests).

**Element Web (lab/operator fallback only):**

1. Create users: `create-family-test-users.sh` (parent + kid in LDAP groups).
2. In the dashboard, add approved friend MXIDs to the kid allowlist.
3. From Element Web on the kid account, try DM to a non-allowlisted MXID → invite/message should fail with `M_FORBIDDEN`.
4. During quiet hours (server timezone in policy), kid messages are denied; parent accounts still work.

## Unit tests (no Synapse)

```bash
pip install -e family/synapse_module[test]
pytest family/synapse_module/tests
```
