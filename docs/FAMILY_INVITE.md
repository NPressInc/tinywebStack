# Household invite flow (link trusted families)

Replaces manual domain + fingerprint swapping (decision 7). Requires **PR1** family dashboard and module.

## Flow

1. **Parent A** (household A) opens **Family dashboard → Link another household → Generate invite**.
2. A shares the one-time URL or token with **Parent B** (out of band).
3. **Parent B** redeems via the dashboard HTML form, the **TinyWeb app** (Family → Accept invite), or by pasting the token into `POST /family/api/link-invites/accept`.
4. B’s server calls A’s public endpoint `POST https://<A>/family/api/invite/verify` with `{token, redeemer_domain}`.
5. A validates the HMAC token and pending nonce, returns Matrix server key material, adds B to `trusted_domains`, and runs `family-sync-federation.sh` (Synapse allowlist + Mobilizon relay peers).
6. B verifies A’s Synapse signing key when needed, adds A to `trusted_domains`, and runs the same federation sync on B.

Redeem logic is shared between HTML and JSON (`tinywebstack_dashboard.link_invite.redeem_link_invite`).

### TinyWeb app JSON (parent bearer)

| Method | Path | Notes |
|--------|------|--------|
| `POST` | `/family/api/link-invites/preview` | `{ "token" }` → inviter domain/name, expiry, `already_linked`, `reachable`. Does not consume the nonce. |
| `POST` | `/family/api/link-invites/accept` | Runs shared redeem → `{ linked_domain, synapse_federation, mobilizon_relay }`. Re-accept when already linked → **409** with `already_linked: true`. Self-link → **400** `cannot link to yourself`. |
| `POST` | `/family/api/link-invites/decline` | Best-effort `POST` to inviter `…/api/invite/decline`; always `{ "declined": true }` locally. |
| `GET` | `/family/api/linked-families` | `{ "linked_families": [{ "domain", "family_name" }] }`. |

Public on the **issuer**: `POST /family/api/invite/decline` with `{ "token" }` (HMAC + pending nonce, same trust model as verify).

Well-known metadata (no auth): `https://<main-domain>/.well-known/tinywebstack-family.json`

## Secrets and files

| Path | Purpose |
|------|---------|
| `/etc/tinywebstack/dashboard.env` | `TWS_INVITE_SECRET` (HMAC) |
| `/etc/tinywebstack/pending-invites.json` | One-time nonces |
| `/etc/tinywebstack/family-policy.json` | `trusted_domains` |

## Manual / lab notes

- Peers must reach each other over HTTPS (lab CA trusted on both nodes).
- `install-family-dashboard.sh` installs passwordless sudo for `www-data` to run `/usr/local/sbin/tws-family-sync-federation`.
- To re-sync after editing policy: `family-sync-federation.sh MAIN_DOMAIN` on the VM.

## Tests

```bash
pytest family/synapse_module/tests/test_invite.py
pytest family/dashboard/tests/test_link_invites_api.py
```
