# Family parent dashboard

Small FastAPI app (server-rendered HTML) for parents to manage kid allowlists and quiet hours. It writes `/etc/tinywebstack/family-policy.json` atomically for the Synapse module.

## Install

```bash
./scripts/vm/remote-run.sh "$IP" install-family-dashboard.sh family-a.family.test
```

Or use `family-init.sh` which runs groups, module, dashboard, and optional test users.

## Auth

- Protected by **YunoHost SSO** (nginx + SSOwat). Only users in the **`parents`** LDAP group may access (configurable via `TWS_PARENTS_GROUP`).
- Behind the scenes the app reads `Remote-User` / `YNH_USER` headers.
- Forms use CSRF tokens (`TWS_CSRF_SECRET` in `/etc/tinywebstack/dashboard.env`).

## URL

After install: `https://<main-domain>/family/` (proxied to `127.0.0.1:8765`).

Parents see:

- List of kids (from the `kids` group)
- Per-kid contact allowlist (MXIDs + optional whole domains)
- Quiet hours (start/end/timezone; supports windows past midnight)
- Link to OwnTracks web UI (parents only)

Kids do **not** receive dashboard or OwnTracks web permissions (`family-groups.sh`).

## OwnTracks app (kid phone)

Configure the [OwnTracks app](https://owntracks.org/) in **HTTP mode** to POST to your recorder endpoint (see YunoHost `owntracks_ynh` docs for URL and credentials). Kids publish location; parents view history on the web map.

## Tests

```bash
pip install -e family/synapse_module -e family/dashboard[test]
pytest family/dashboard/tests
```
