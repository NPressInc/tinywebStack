# Family events (Mobilizon)

tinywebStack uses **[Mobilizon](https://joinmobilizon.org/)** from the YunoHost catalog as the family **events** app: groups, invites, and RSVPs (roughly “Facebook Events” for self-hosted homes). The portal tile is labeled **Events** (TinyWeb stack, not YunoHost branding).

**Product decision (2026):** Keep Mobilizon **with cross-family federation** on trusted homes. **Event pages, profiles, and ActivityPub objects are intentionally reachable without portal login** on `mobilizon.federation` URL paths — SSOwat cannot distinguish a browser from a federated peer. **Default new events to `PUBLIC`** (Mobilizon’s web UI default): federated copies on trusted homes need a visibility that actually replicates over ActivityPub; lab retest showed **`UNLISTED` did not reach linked families** while **`PUBLIC` did within seconds**. Parents who want less local listing can still pick other visibilities in Mobilizon when creating an event.

**Authentication:** YunoHost SSO opens the Mobilizon web UI, but Mobilizon performs a **second LDAP login** (same email/password as the YunoHost user). There is no OIDC/SSO token pass-through in the catalog app today. The family dashboard notes this next to **open events**. LDAP login is restricted to members of the **`events-users`** group (parents, federation-test, enabled kids, `twsowner`); toggled-off kids are removed from that group and cannot authenticate via `/api` even though federation URLs stay public.

**Lab architecture:** one Mobilizon instance per family node at `mobilizon.<main-domain>` (see [test-nodes.md](test-nodes.md)). The catalog package supports **arm64** (spark VMs) and amd64.

## Permission model

| Action | Parents | Kids (events enabled) | Kids (events disabled) | Federation-test group | Visitors / public |
|--------|---------|------------------------|-------------------------|----------------------|-------------------|
| Open Mobilizon UI (`mobilizon.main`) | Yes | Yes (per-user grant) | **No** (SSO redirect) | Yes (lab) | No |
| ActivityPub + public pages (`mobilizon.federation`) | — | — | — | — | **Yes** |
| LDAP / GraphQL login (`events-users` + `/api`) | Yes | Yes | **No** | Yes | No* |
| Create groups / org-wide admin | Yes (Mobilizon + **`twsowner`**) | No | No | — | No |
| Create events | Yes | Yes | N/A | Yes | No |
| See **trusted** linked home’s federated events | Yes | Yes | N/A | Yes | Via public URL if known |
| See **non-trusted** federated instances | No** | No** | N/A | No** | No |
| Self-service Mobilizon registration | No | No | No | No | No |
| Parent toggles kid access | Dashboard **Events** checkbox | — | — | — | — |

\*Public `/api` is reachable without portal cookie, but **login** still requires LDAP membership in `events-users`.

\*\*Enforced by **`mobilizon-federation-sync.sh`**: outgoing `addInstance` only for trusted peers; incoming relays **accepted** only for trusted Mobilizon hostnames. **Never** probe public instances during sync — lab verify uses a **passive** `instance.followedStatus` check only.

### Kid toggle

- **`mobilizon.main`:** per-kid YunoHost permission (no whole-`kids` group grant).
- **`events-users` LDAP group:** maintained by `scripts/lib/apply_mobilizon_permissions.py` — toggled-off kids lose LDAP login and (best-effort) active Mobilizon sessions.

## Scripts

| Script | Role |
|--------|------|
| `scripts/vm/install-mobilizon.sh` | Catalog install, lab TLS, bundled CA patch |
| `scripts/vm/mobilizon-lab-ca-trust.sh` | Lab-only append to Mobilizon castore/certifi bundles |
| `scripts/lib/setup_mobilizon_permissions.py` | `mobilizon.federation` + `mobilizon.main` (`yunohost.init`, fail loud) |
| `scripts/vm/mobilizon-family-config.sh` | Registrations off, LDAP `events-users` filter |
| `scripts/vm/mobilizon-federation-sync.sh` | ActivityPub allowlist ↔ `trusted_domains` |
| `scripts/lib/apply_mobilizon_permissions.py` | Kid SSO + `events-users` membership |
| `scripts/spark/verify-events-e2e.sh` | Lab end-to-end check |

Portal tile logo: `brand/portal/events-tile.png`. Manual spark steps: [templates/spark-events-manual-steps.md](templates/spark-events-manual-steps.md).

## Lab-only TLS

Mobilizon’s Elixir client uses **bundled** CA files, not only system trust. On test nodes, `mobilizon-lab-ca-trust.sh` appends the lab CA to those bundles (idempotent marker `# tinywebstack-lab-ca-append`). Re-run after Mobilizon package upgrades. **Do not run on production.**

## Dashboard

Parents use **Family home → open events** (`TWS_EVENTS_URL`). Expect one Mobilizon LDAP sign-in with the same credentials as YunoHost. Child **Chat rules → Events** updates policy and runs `family-events-perms.sh`.
