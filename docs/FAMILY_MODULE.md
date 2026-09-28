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

This pip-installs the module into the Synapse venv, drops `/etc/matrix-synapse/conf.d/tinywebstack-family.yaml`, sets `encryption_enabled_by_default_for_room_type: off`, and restarts Synapse.

## Policy file

Path: `/etc/tinywebstack/family-policy.json` (configurable via module config `policy_path`).

The parent dashboard syncs kid MXIDs from the YunoHost `kids` group and parent MXIDs from `parents`. Group names are overridable with `TWS_KIDS_GROUP` / `TWS_PARENTS_GROUP`.

### Kid join rule

A kid may **invite** / be **invited** / **join** / **message** only when every other human in the room is:

- on that kid’s MXID allowlist,
- on an allowlisted domain entry for that kid,
- a **local parent** (`parent_mxids` on the same `server_name`), or
- the kid themselves.

Parents (listed in `parent_mxids`) are not subject to kid allowlists. Server admins bypass some Synapse hooks upstream — family **parents should not be Synapse admins**.

Invalid or missing policy → **fail closed** for kids (deny invites/joins/messages).

## Testing with Element X

1. Create users: `create-family-test-users.sh` (parent + kid in LDAP groups).
2. In the dashboard, add approved friend MXIDs to the kid allowlist.
3. From Element X on the kid account, try DM to a non-allowlisted MXID → invite/message should fail with `M_FORBIDDEN`.
4. During quiet hours (server timezone in policy), kid messages are denied; parent accounts still work.

## Unit tests (no Synapse)

```bash
pip install -e family/synapse_module[test]
pytest family/synapse_module/tests
```
