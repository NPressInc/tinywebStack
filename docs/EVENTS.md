# Family events (Mobilizon)

tinywebStack uses **[Mobilizon](https://joinmobilizon.org/)** from the YunoHost catalog as the family **events** app: groups, invites, and RSVPs (roughly “Facebook Events” for self-hosted homes). The portal tile is labeled **Events** (TinyWeb stack, not YunoHost branding).

**Authentication:** YunoHost SSO opens the Mobilizon web UI, but Mobilizon still performs its own **LDAP login** (email + password). There is no single sign-on token pass-through today. New LDAP users may have no Mobilizon profile until first login; family scripts call `createPerson` when needed (verify script and operators should ensure a **default actor** exists). **`mobilizon.main`** uses `auth_header=false` so SSOwat does not overwrite Mobilizon’s `Authorization: Bearer` header (required for GraphQL and browser sessions).

**Lab architecture:** one Mobilizon instance per family node at `mobilizon.<main-domain>` (see [test-nodes.md](test-nodes.md)). The catalog package supports **arm64** (spark VMs) and amd64.

## Permission model

| Action | Parents | Kids (events enabled) | Kids (events disabled) | Federation-test group | Visitors / public |
|--------|---------|------------------------|-------------------------|----------------------|-------------------|
| Open Mobilizon UI (`mobilizon.main`) | Yes | Yes (per-user grant) | **No** | Yes (lab) | No |
| ActivityPub / GraphQL API (`mobilizon.federation` paths) | — | — | — | — | **Yes** (no portal cookie) |
| Create groups / org-wide admin | Yes (Mobilizon + **`twsowner`**) | No | No | — | No |
| Create events | Yes | Yes (within instance) | N/A | Yes | No |
| See local family events | Yes | Yes | N/A | Yes | No |
| See **trusted** linked home’s public federated events | Yes | Yes* | N/A | Yes | No |
| See **non-trusted** federated instances | No** | No** | N/A | No** | No |
| Self-service Mobilizon registration | No (`registrations_open: false`) | No | No | No | No |
| Parent toggles kid access to events | Via dashboard checkbox on child chat rules | — | — | — | — |

\*Kids still only see federated content from **instances your home follows and approved** (ActivityPub). Pairwise trust is driven by `trusted_domains` in `/etc/tinywebstack/family-policy.json`, same as Matrix (see [FAMILY_INVITE.md](FAMILY_INVITE.md)).

\*\*Enforced by **`mobilizon-federation-sync.sh`**: outgoing `addInstance` only for trusted peers; incoming relays **accepted** only for trusted Mobilizon hostnames and **rejected** otherwise. **Never** call `addInstance` for a public probe (e.g. `mobilizon.fr`) during sync — the lab verify script uses a **passive** check only (`instance.followedStatus`).

### Kid toggle

The **`kids` YunoHost group is not granted** `mobilizon.main` (group-wide remove would block per-kid toggles). `scripts/lib/apply_mobilizon_permissions.py` adds or removes **`mobilizon.main` per kid** from `events_enabled` in policy JSON.

### Not enforced server-side today

| Concern | Limitation |
|---------|------------|
| Kid only RSVPs to “allowlisted contacts” events | Mobilizon has no per-user federation ACL; kid SSO gate + trusted-instance federation are the server levers. |
| Private event visibility across homes | Only **public** federated events replicate. |
| Mobilizon `createUser` when registrations are closed | Upstream may return HTTP 500 (`FunctionClauseError`); expected — no account must be created. |

## Scripts

| Script | Role |
|--------|------|
| `scripts/vm/install-mobilizon.sh` | Catalog install, lab TLS, lab CA trust drop-in, family config |
| `scripts/lib/setup_mobilizon_permissions.py` | `mobilizon.federation` (visitors) + `mobilizon.main` (`auth_header=false`) |
| `scripts/vm/mobilizon-family-config.sh` | Registrations off + family config snippet |
| `scripts/vm/mobilizon-federation-sync.sh` | ActivityPub allowlist ↔ `trusted_domains` (**admin: `twsowner`**) |
| `scripts/vm/family-sync-federation.sh` | Matrix allowlist **and** Mobilizon sync |
| `scripts/lib/apply_mobilizon_permissions.py` | Per-kid `events_enabled` → `mobilizon.main` |
| `scripts/spark/verify-events-e2e.sh` | Lab check: public federation URLs, admin sync, cross-home RSVP, passive probe |

`family-init.sh` installs Mobilizon after base groups. Portal tile logo: `brand/portal/events-tile.png` via `scripts/lib/portal_tiles.sh`.

## Lab-only: TLS and Mobilizon outbound HTTPS

- **`yunohost-lab-tls.sh`** issues a lab CA cert for `mobilizon.<domain>` during install.
- Mobilizon’s Elixir HTTP client uses its own CA bundle; on test nodes, `install-mobilizon.sh` installs a **systemd drop-in** (`SSL_CERT_FILE` / `ERLANG_SSL_CACERTFILE` → combined system + lab CA). Do not use this pattern on production nodes with public CAs only.

## Dashboard

Parents open **Family home → open events** (when `TWS_EVENTS_URL` is set). On each child’s **Chat rules** page, **Allow this child to open the family events app** maps to `events_enabled` in policy JSON and triggers `family-events-perms.sh` / permission refresh.
