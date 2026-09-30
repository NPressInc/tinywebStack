# Family calendars (Nextcloud Calendar)

v1 uses **Nextcloud Calendar** on each home server with **CalDAV** clients on phones (DAVx5 on Android, Apple Calendar on iOS). The Nextcloud web UI is **not** part of the parent story — the **TinyWeb family dashboard** stays the only web UI families need day to day.

Install flow (lab or production node):

1. `install-nextcloud-calendar.sh` — YunoHost catalog app, Calendar enabled, LDAP/SSO.
2. `family-init.sh` — after family member users exist, `setup-family-calendars.sh` creates shared calendars and writes `/etc/tinywebstack/calendar-state.json`. The member list defaults to the lab pair (`parent,kid`); pass `--users "william,sophie,emma"` (or `TWS_FAMILY_USERS` in `config/local.env`) to provision a real-named household. The first user owns the shared calendars (override with `TWS_FAMILY_OWNER`).
3. `family-groups.sh` — grants `nextcloud.main` to `parents`, `kids`, and `federation-test`, keeps **`visitors`** so CalDAV clients reach Nextcloud without a portal SSO cookie, and **hides** the Nextcloud portal tile (CalDAV-only v1).

### CalDAV vs Nextcloud web login (visitors permission)

YunoHost **`visitors`** on `nextcloud.main` lets nginx pass traffic to Nextcloud for **Basic-auth CalDAV** (`/nextcloud/remote.php/dav`, `/.well-known/caldav`) without an SSOwat session cookie. That also means anyone who knows the URL can open **Nextcloud’s own login page** at `/nextcloud/login` (LDAP passwords still required; YunoHost/Nextcloud brute-force protection applies).

We accept this trade-off for v1 phone clients. The **TinyWeb dashboard** remains the family-facing UI; the Nextcloud portal tile stays hidden. A tighter follow-up is to restrict `visitors` to DAV/well-known paths only if YunoHost’s per-URL permission model allows it, while keeping the full web UI behind SSO for browsers.

CalDAV base URL (default path):

```text
https://nextcloud.YOUR.MAIN.DOMAIN/nextcloud/remote.php/dav
```

Parents open **Family home → Phone calendars** for setup text and a QR code (server URL + username).

## Calendar layout

| Calendar | Owner (CalDAV) | Shared with | Purpose |
|----------|----------------|-------------|---------|
| **Family** (`tws-family`) | `parent` | `family-<node>` + `federation-test` (lab) | Shared events everyone should see |
| **Parents** (`tws-parents`) | `parent` | `parents` | Adults-only scheduling |
| **Kids** (`tws-kids`) | `parent` | `kids` (+ `parents` read/write) | Children’s activities; parents manage |
| **Personal** | each user | that user only | Per-person calendar (`personal-<user>` or default) |

Group `family-<node>` is created automatically (e.g. `family-family-a` on the `family-a` test node) and includes the provisioned family members (lab defaults: `parent` and `kid`).

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

### Upgrading nodes after calendar fixes

Re-sync scripts, then on each VM (`IP` from `virsh domifaddr`, node name `family-a` / `family-b`). On spark, libvirt uses the **system** URI (see [test-nodes.md](test-nodes.md)):

```bash
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"
# or: sg libvirt -c 'bash -s' <<'SH' … SH

IP_A=$(virsh domifaddr tws-family-a | awk '/ipv4/ {print $4}' | cut -d/ -f1)
IP_B=$(virsh domifaddr tws-family-b | awk '/ipv4/ {print $4}' | cut -d/ -f1)

while read -r node domain ip; do
  [[ -z "$node" || -z "$domain" || -z "$ip" ]] && continue
  ./scripts/vm/remote-run.sh "$ip" install-nextcloud-calendar.sh "$domain" "$node"
  ./scripts/vm/remote-run.sh "$ip" setup-family-calendars.sh "$domain" "$node"
  ./scripts/vm/remote-run.sh "$ip" family-groups.sh
  ./scripts/vm/remote-run.sh "$ip" family-init.sh "$domain" "$node"
done <<EOF
family-a family-a.family.test $IP_A
family-b family-b.family.test $IP_B
EOF
```

(`family-init.sh` reinstalls the dashboard; do not pass a node name to `install-family-dashboard.sh` — it only accepts `MAIN_DOMAIN`.)

Always pass **MAIN_DOMAIN** and **NODE_NAME** (spark node id, not FQDN alone) to `remote-run.sh` when secrets are needed.

Copy-paste **Manual steps on spark** for PRs from [docs/templates/spark-calendar-manual-steps.md](templates/spark-calendar-manual-steps.md).

## What we cannot enforce (v1)

- Per-kid **contact allowlists** for calendar invites (Synapse module does not apply here).
- Hiding individual events on a shared calendar from specific kids (need separate calendars or client-side accounts).
- Cross-domain calendar trust without Nextcloud federation or email — tracked as follow-up work.
