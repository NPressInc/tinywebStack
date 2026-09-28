# Household invite flow (link trusted families)

Replaces manual domain + fingerprint swapping (decision 7). Requires **PR1** family dashboard and module.

## Flow

1. **Parent A** (household A) opens **Family dashboard → Link another household → Generate invite**.
2. A shares the one-time URL or token with **Parent B** (out of band).
3. **Parent B** opens **Redeem invite**, pastes the token.
4. B’s server calls A’s public endpoint `POST https://<A>/family/api/invite/verify` with `{token, redeemer_domain}`.
5. A validates the HMAC token and pending nonce, returns Matrix server key material, adds B to `trusted_domains`, and runs `family-sync-federation.sh`.
6. B verifies A’s Synapse signing key via `https://<matrix-A>/_matrix/key/v2/server`, adds A to `trusted_domains`, and runs federation sync.

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
```
