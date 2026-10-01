# tinywebstack-permissions

Declarative role→permission store (F1.3) for the tinywebStack family layer.

The SQLite DB at `/etc/tinywebstack/permissions.db` (override with
`TWS_PERMISSIONS_DB`) is **runtime state**. Two in-repo role files
(`tinywebstack_permissions/roles/parent.yaml`, `kid.yaml`) are the seed
migrations that define role defaults; per-user overrides live in
`user_permissions`.

| Table | Purpose |
|-------|---------|
| `meta` | schema_version, server_name, trusted_domains, reject_encryption |
| `roles` | role name + is_admin flag |
| `role_permissions` | role defaults (key/value JSON) |
| `users` | mxid → username, role, server_name |
| `user_permissions` | per-user overrides (allowlists, quiet hours, …) |

Permission keys: `can_create_rooms`, `can_create_group_rooms`,
`can_send_3pid_invites`, `can_publish_rooms`, `events_enabled`,
`mobilizon_role`, `allowlist_mxids`, `allowlist_domains`, `quiet_hours`.

## Library API

```python
from tinywebstack_permissions import PermissionsDB

with PermissionsDB() as db:                      # path via env/default
    db.seed_roles([".../roles/parent.yaml", ".../roles/kid.yaml"])
    db.set_role("@kid:family.test", "kid")
    db.set_permission("@kid:family.test", "allowlist_mxids", ["@friend:p.test"])
    ps = db.get_permissions("kid")                # PermissionSet
    db.revoke_permission("kid", "quiet_hours")    # back to role default
    dump = db.export_dict()                       # backup / restore
```

`SqliteFamilyPolicyStore` gives the Synapse module a `PolicyStore`-compatible
reader that prefers the DB and falls back to `family-policy.json` when the DB
file does not exist (safe degrade; enforcement verdicts unchanged).

## CLI

```sh
tws-permissions seed --policy /etc/tinywebstack/family-policy.json
tws-permissions show kid
tws-permissions export > backup.json
```

Seeding is idempotent: role YAMLs are authoritative for role defaults,
`seed --policy` imports the household (parents/kids + per-kid overrides)
without clobbering newer per-user overrides on repeat runs.
