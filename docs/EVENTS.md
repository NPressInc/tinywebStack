# Family events (Mobilizon)

tinywebStack uses **[Mobilizon](https://joinmobilizon.org/)** from the YunoHost catalog as the family **events** app: groups, invites, and RSVPs (roughly “Facebook Events” for self-hosted homes). Accounts use **YunoHost SSO/LDAP**; the portal tile is labeled **Events** (TinyWeb stack, not YunoHost branding).

**Lab architecture:** one Mobilizon instance per family node at `mobilizon.<main-domain>` (see [test-nodes.md](test-nodes.md)). The catalog package supports **arm64** (spark VMs) and amd64.

## Permission model

| Action | Parents | Kids (events enabled) | Kids (events disabled) | Federation-test group | Visitors / public |
|--------|---------|------------------------|-------------------------|----------------------|-------------------|
| Open Mobilizon via SSO (`mobilizon.main`) | Yes | Yes | **No** (YunoHost permission removed) | Yes (lab) | No |
| Create groups / org-wide admin | Yes (Mobilizon + YunoHost admin for installers) | No (`only_admin_can_create_groups`) | No | — | No |
| Create events | Yes | Yes (within instance) | N/A (no app access) | Yes | No |
| See local family events | Yes | Yes | N/A | Yes | No |
| See **trusted** linked home’s public federated events | Yes | Yes* | N/A | Yes | No |
| See **non-trusted** federated instances | No** | No** | N/A | No** | No |
| Self-service Mobilizon registration | No (`registrations_open: false`) | No | No | No | No |
| Parent toggles kid access to events | Via dashboard checkbox on child chat rules | — | — | — | — |

\*Kids still only see federated content from **instances your home follows and approved** (ActivityPub). Pairwise trust is driven by `trusted_domains` in `/etc/tinywebstack/family-policy.json`, same as Matrix (see [FAMILY_INVITE.md](FAMILY_INVITE.md)).

\*\*Enforced by **`mobilizon-federation-sync.sh`**: outgoing `addInstance` only for trusted peers; incoming relays **accepted** only for trusted Mobilizon hostnames and **rejected** otherwise. Mobilizon has **no Synapse-style domain whitelist** in config — operators should not manually approve random instances in Mobilizon admin.

### Not enforced server-side today

| Concern | Limitation |
|---------|------------|
| Kid only RSVPs to “allowlisted contacts” events | Mobilizon has no per-user federation ACL; kid SSO gate + trusted-instance federation are the server levers. Cross-home social rules remain Matrix-centric ([FAMILY_MODULE.md](FAMILY_MODULE.md)). |
| Private event visibility across homes | Only **public** federated events replicate; private events stay on the origin instance. |
| Per-group `family-<name>` YunoHost groups | Mobilizon groups are **in-app**; mapping household YunoHost groups → Mobilizon groups is not automated (follow-up). |

## Scripts

| Script | Role |
|--------|------|
| `scripts/vm/install-mobilizon.sh` | Catalog install on `mobilizon.<main>` (idempotent) |
| `scripts/vm/mobilizon-family-config.sh` | Registrations off + family config snippet |
| `scripts/vm/mobilizon-federation-sync.sh` | ActivityPub allowlist ↔ `trusted_domains` |
| `scripts/vm/family-sync-federation.sh` | Matrix allowlist **and** Mobilizon sync |
| `scripts/lib/apply_mobilizon_permissions.py` | Per-kid `events_enabled` → `mobilizon.main` |
| `scripts/spark/verify-events-e2e.sh` | Lab check: install, SSO login, cross-home RSVP, reject probe |

`family-init.sh` installs Mobilizon after base groups. Portal tiles: `scripts/lib/portal_tiles.sh` (`show_tile True` / `False`).

## Dashboard

Parents open **Family home → open events** (when `TWS_EVENTS_URL` is set). On each child’s **Chat rules** page, **Allow this child to open the family events app** maps to `events_enabled` in policy JSON and triggers a permission refresh.
