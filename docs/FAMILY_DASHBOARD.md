# Family parent dashboard

Small FastAPI app (server-rendered HTML) for parents. **This is the only web interface a non-technical family should need** for day-to-day use. YunoHost, Synapse, and OwnTracks admin screens are for technical users and installers only.

The dashboard writes `/etc/tinywebstack/family-policy.json` for the Synapse module and calls narrowly-scoped **sudo helpers** on the node for account changes.

## Install

```bash
./scripts/vm/remote-run.sh "$IP" install-family-dashboard.sh family-a.family.test family-a
```

Or use `family-init.sh` which runs groups, module, dashboard, and optional test users.

## Branding

Family-facing UI uses **TinyWeb** branding (vendored from [tinyweb.win](https://tinyweb.win)). SSO login theming is applied by `install-tinyweb-portal-branding.sh` — see [TINYWEB_BRANDING.md](TINYWEB_BRANDING.md).

## Auth

- Protected by **YunoHost SSO** (nginx + SSOwat). Only users in the **`parents`** LDAP group may access (configurable via `TWS_PARENTS_GROUP`).
- Behind the scenes the app trusts **`YNH_USER` only** (SSOwat). Nginx must set `proxy_set_header Remote-User ""` so clients cannot spoof identity.
- Forms use CSRF tokens (`TWS_CSRF_SECRET` in `/etc/tinywebstack/dashboard.env`).

## URL

After install: `https://<main-domain>/family/` (proxied to `127.0.0.1:8765`).

Parents see (plain language):

- **Family members** — add/remove parents and children, reset passwords, see chat (Matrix) status
- **Location phone setup** — QR code for OwnTracks on each child’s phone; map link for parents only
- **Household invite** — create or redeem one-time links ([FAMILY_INVITE.md](FAMILY_INVITE.md))
- Per-child **contacts & quiet hours** (allowlists, bedtime rules)

Kids do **not** receive dashboard or OwnTracks web permissions (`family-groups.sh`).

## TinyWeb mobile app (Stage 1 API)

The dashboard exposes JSON under `/family/api/` for the **TinyWeb** iOS/Android app (bearer token `tws_…` after enrollment). Discovery fields are in `GET /.well-known/tinywebstack-family.json` (`app_api_version`, `enroll_url`, `matrix_homeserver_url`, `caldav_root`, …).

- **Enrollment:** public `POST /family/api/app/enroll` (password or parent-issued one-time code). Codes are created on **Family members → person → Set up the TinyWeb app** (or `POST /family/api/app/codes` for parents).
- **Device store:** `/etc/tinywebstack/app-devices.db` (`TWS_APP_DEVICES_DB`), mode `600`, `www-data`.
- **Auth:** app routes accept `Authorization: Bearer tws_…`; browser parents still use SSO on HTML routes. Nginx clears `YNH_USER` on `/family/api/*` so clients cannot spoof SSO headers.
- **Revoke:** member detail page or `POST /family/api/app/devices/{id}/revoke`. Password reset revokes all devices for that user.

See [TINYWEB_APP_PLAN.md](TINYWEB_APP_PLAN.md) for request/response shapes and the Stage 1 Matrix limitation for code-based enrollment.

## Privileged helpers (node)

Installed by `install-family-dashboard.sh`:

| Path | Purpose |
|------|---------|
| `/usr/local/sbin/tws-family-dashboard-privileged` | YunoHost user create/delete/password, Synapse user status, OwnTracks kid credentials, Nextcloud app passwords, Matrix device delete |
| `/usr/local/sbin/tws-family-sync-federation` | Merge `trusted_domains` into Synapse allowlist |

`www-data` may run these via `/etc/sudoers.d/tinywebstack-family-dashboard` (NOPASSWD).

## Synapse admin token (optional, for chat status)

To show “active / not signed in yet” from the Synapse Admin API, place a bearer token in:

`/etc/tinywebstack/synapse-admin-token` (mode `600`, group `www-data`; auto-provisioned on install when Synapse is reachable)

Dashboard SSO permissions are created on the **Synapse app** (e.g. `synapse.family_dashboard`, `synapse.family_public`), not `core_family.*`. Match `TWS_DASHBOARD_PERM` / `TWS_DASHBOARD_PUB_PERM` in `dashboard.env`.

If the file is empty, the dashboard still works; chat status copy explains that the child should open Element once.

## OwnTracks on a child’s phone

Use **Family members → child → Location phone setup** to generate a **QR code** (HTTP mode). Parents open the map at the location URL; children do not get the web map tile (`family-groups.sh`).

Manual fallback: [OwnTracks app](https://owntracks.org/) HTTP mode using credentials from `/etc/tinywebstack/owntracks-kids.json` (root-only; use dashboard QR instead).

## Tests

```bash
pip install -e family/synapse_module -e family/dashboard[test]
pytest family/dashboard/tests
```
