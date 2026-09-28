# Family calendars (Nextcloud Calendar)

v1 uses **Nextcloud Calendar** on each home server with **CalDAV** clients on phones (DAVx5 on Android, Apple Calendar on iOS). The Nextcloud web UI is **not** part of the parent story — the **TinyWeb family dashboard** stays the only web UI families need day to day.

Install flow (lab or production node):

1. `install-nextcloud-calendar.sh` — YunoHost catalog app, Calendar enabled, LDAP/SSO.
2. `family-init.sh` — after parent/kid users exist, `setup-family-calendars.sh` creates shared calendars and writes `/etc/tinywebstack/calendar-state.json`.
3. `family-groups.sh` — grants `nextcloud.main` to `parents`, `kids`, and `federation-test`, and **hides** the Nextcloud portal tile (CalDAV-only v1).

CalDAV base URL (default path):

```text
https://nextcloud.YOUR.MAIN.DOMAIN/nextcloud/remote.php/dav
```

Parents open **Family home → Phone calendars** for setup text and a QR code (server URL + username).

## Calendar layout

| Calendar | Owner (CalDAV) | Shared with | Purpose |
|----------|----------------|-------------|---------|
| **Family** (`tws-family`) | `parent` | YunoHost group `family-<node>` (whole household) | Shared events everyone should see |
| **Parents** (`tws-parents`) | `parent` | `parents` | Adults-only scheduling |
| **Kids** (`tws-kids`) | `parent` | `kids` (+ `parents` read/write) | Children’s activities; parents manage |
| **Personal** | each user | that user only | Per-person calendar (`personal-<user>` or default) |

Group `family-<node>` is created automatically (e.g. `family-family-a` on the `family-a` test node) and includes lab users `parent` and `kid`.

## Permission model

| Actor | See family calendar | Edit family calendar | See parents calendar | Edit parents calendar | See kids calendar | Edit kids calendar | See own personal | Invite others (in-app) |
|-------|--------------------|----------------------|----------------------|----------------------|-------------------|--------------------|------------------|------------------------|
| **Parent** | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes (same server users/groups) |
| **Kid** | Yes | Yes* | No | No | Yes | Yes* | Yes | Limited† |
| **Federation-test user** (lab) | Yes | Yes | No | No | No | No | Yes | Same as kid/parent role |

\*Nextcloud calendar ACLs are **calendar-level**, not per-event kid allowlists. Parents should use the **Parents** calendar for sensitive plans. Finer kid rules match the Matrix allowlist story and are **not enforced in Nextcloud v1** — see gaps below.

†Invites between users on the **same** home server use CalDAV/iTIP (accept/decline in DAVx5 or iOS). Email (iMIP) delivery depends on server mail configuration and is **not** required for v1 lab tests.

### Cross-household (linked families)

| Approach | v1 status |
|----------|-----------|
| Same-server invite (parent → kid) | **Supported** (lab verify script) |
| Matrix-style kid allowlist for calendar | **Not enforced** — document only; use parenting norms + separate calendars |
| Invite `@friend:other.family.test` to an event | **Follow-up** — requires federated Nextcloud calendar sharing or iMIP email between domains |
| Two home servers (`family-a` / `family-b`) | Install calendar on both; use Matrix for coordination until federated calendar is productized |

## Mobile setup

### Android (DAVx5)

1. Install [DAVx5](https://www.davx5.com/).
2. Add account → **Login with URL and user name**.
3. Base URL: CalDAV root above; user: your YunoHost username; password: your family password (parents reset kid passwords from the dashboard).
4. Enable sync for **Family**, **Personal**, and other shared calendars offered.

### iOS

1. Settings → Calendar → Accounts → Add Account → **Other** → **Add CalDAV Account**.
2. Server: `nextcloud.YOUR.MAIN.DOMAIN`; use Advanced → Account URL ending in `/remote.php/dav/principals/users/USERNAME/` if needed.
3. Username / password: YunoHost SSO credentials.

## Lab verification (spark)

After `family-init.sh` on both VMs:

```bash
./scripts/spark/verify-calendar-e2e.sh family-a family-a.family.test
./scripts/spark/verify-calendar-e2e.sh family-b family-b.family.test
```

Checks CalDAV login for `parent` and `kid`, then a parent → kid invite accept round trip on the shared family calendar.

Use `LAB_PASSWORD=dummydummy` in `config/local.env` so test secrets stay predictable (never in production).

## What we cannot enforce (v1)

- Per-kid **contact allowlists** for calendar invites (Synapse module does not apply here).
- Hiding individual events on a shared calendar from specific kids (need separate calendars or client-side accounts).
- Cross-domain calendar trust without Nextcloud federation or email — tracked as follow-up work.
