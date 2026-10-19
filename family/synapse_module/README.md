# tinywebstack-family (Synapse module)

Enforces per-kid Matrix contact allowlists and quiet hours. E2EE is on by default; optional `reject_encryption` blocks `m.room.encryption` state events.

Policy file (default): `/etc/tinywebstack/family-policy.json` — written by the family dashboard.

Install on a node: `scripts/vm/install-family-module.sh` (see [docs/FAMILY_MODULE.md](../../docs/FAMILY_MODULE.md)).
