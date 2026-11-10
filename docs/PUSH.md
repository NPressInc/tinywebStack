# Push notifications (privacy-first)

TinyWeb wakes phones for new Matrix messages **without putting message text in push payloads**. The app fetches and decrypts on device, then shows a local notification.

## Architecture

```
Matrix client (app)
    |  POST /pushers/set  (format=event_id_only, pushkey=full ntfy topic URL | APNs token)
    v
Synapse (homeserver)
    |  HTTP POST to pusher data.url (loopback)
    v
+-----------+       +-----------+
| ntfy      |       | Sygnal    |
| :8090     |       | :5000     |
| Matrix GW |       | APNs/FCM  |
+-----------+       +-----------+
    |                     |
    v                     v
UnifiedPush topic      Apple Push (generic alert)
(ntfy app / embedded)   optional FCM
```

Public HTTPS origin: **`https://push.<main-domain>/`** (dedicated vhost; nginx → loopback ntfy/Sygnal). In production you need a DNS **A/AAAA** for `push.<domain>`; the installer adds the YunoHost domain and TLS. Matrix `pushkey` for Android must be the **full topic URL** under that origin (e.g. `https://push.example.com/upXXXXXXXX?up=1`), not a bare topic name.

- **Android (primary):** UnifiedPush via self-hosted **ntfy** on the box. Matrix uses ntfy’s `/_matrix/push/v1/notify` gateway on loopback. ntfy uses **`auth-default-access: deny-all`** with **`everyone` read-write only on `up*` topics** (unguessable instance ids); visitor rate limits apply; **12h** message cache for briefly offline devices. Synapse reaches ntfy on `127.0.0.1` only (`ip_range_whitelist`).
- **iOS:** **Sygnal** on loopback with APNs `default_payload` generic title/body (no room/sender/content). The APNs auth key is **TinyWeb's**, the same key on every family box. Until that operator key is installed, a **loopback health stub** listens on the Sygnal port and **refuses** `/_matrix/push/v1/notify` (HTTP 503). It does not answer as if the push were delivered.
- **FCM:** Sygnal app entry for `win.tinyweb.tinyweb.android` using **TinyWeb's** Firebase service account (HTTP v1). Android's primary path is still ntfy/UnifiedPush; FCM is the TinyWeb-operated Google path, not a file a parent uploads. Missing FCM credentials refuse Sygnal delivery the same way missing APNs credentials do.

## Privacy model

| Party | Sees |
|--------|------|
| Apple / Google (if FCM enabled) | Device token, timing, generic alert — not message bodies from TinyWeb payloads |
| Push gateway (ntfy/Sygnal on your box) | `event_id`, `room_id`, counts — no plaintext message |
| App | Full message after authenticated fetch from your box |

Enrollment returns only public gateway URLs and app IDs — **no secrets**.

Synapse is configured with `push.include_content: false` and apps always register `event_id_only` pushers. The `tinywebstack_family` module includes `pusher_policy.py` documenting the required shape, but **Synapse has no module hook to reject rogue pushers** — enforcement is: app + Synapse config + lab test.

## Who holds the keys

Push uses **one TinyWeb APNs key and one TinyWeb Firebase service account** on every family box. A parent never uploads a `.p8` or a service-account JSON during unboxing. The app bundle id is TinyWeb's (`win.tinyweb.tinyweb`); families do not create their own Apple or Firebase app for v1.

`install-push.sh` calls `configure-push-credentials.sh`, which runs `scripts/lib/push_operator_config.py`. Default credential source is `tinyweb`. The same secrets are injected by William or the control plane (environment variables, or files under `/etc/tinywebstack/secrets/push/`). Enrollment still returns only gateway URLs and app ids — no key material.

The old per-family path `/etc/tinywebstack/secrets/apns/AuthKey.p8` (`TWS_APNS_KEY_PATH`) is **not** read in the default source. It is not a v1 unboxing step.

## Secrets William provides

These are not in git and are not required for unit tests. Place them on the control plane and on each box before a production push install. Copy `config/push-operator.env.example` to `/etc/tinywebstack/secrets/push/operator.env` (`chmod 600`) for the ids. Put the key files beside it (`chmod 640`, group `tinywebstack-sygnal`).

| Secret | How it is provided | Notes |
|--------|--------------------|--------|
| APNs auth key (`.p8`) | `TWS_APNS_KEY` (PEM), `TWS_APNS_KEY_B64`, `TWS_APNS_KEY_FILE`, or `/etc/tinywebstack/secrets/push/tinyweb-apns-authkey.p8` | Apple Developer → Keys → Apple Push Notifications. One key for the TinyWeb app. PKCS#8 PEM. |
| APNs key id | `TWS_APNS_KEY_ID` | 10 characters, from that same Apple key. |
| Apple team id | `TWS_APNS_TEAM_ID` | 10-character team id of TinyWeb's Apple developer account. |
| APNs bundle id | `TWS_APNS_BUNDLE_ID` | Default `win.tinyweb.tinyweb`. This is the APNs topic. |
| APNs environment | `TWS_APNS_ENV` | `production` (default for `tinyweb`) or `sandbox`. |
| FCM service account | `TWS_FCM_SERVICE_ACCOUNT_JSON`, `TWS_FCM_SERVICE_ACCOUNT_JSON_B64`, `TWS_FCM_SERVICE_ACCOUNT_FILE`, or `/etc/tinywebstack/secrets/push/tinyweb-fcm-service-account.json` | Firebase service account for the TinyWeb Android app (`type` `service_account`). |
| FCM project id | `TWS_FCM_PROJECT_ID` | Optional. Taken from `project_id` in the JSON. If set, it must match. |

Process environment wins over `operator.env`. `operator.env` is single-line `KEY=value` only; put the `.p8` and the JSON in files (or pass PEM/JSON via the environment, including base64). Never commit filled-in files, tokens, or private keys.

Sygnal is not started for real delivery until **both** the APNs set and the FCM service account validate. A missing or unusable secret exits `configure-push-credentials.sh` with status **2** and the message `Delivery is not configured`. The status file `/etc/tinywebstack/push/credential-status.json` records `configured` and `delivery` (`sygnal` or `refused`) plus missing variable **names**. It does not contain the `.p8`, the Firebase private key, the key id, or the team id. The script does not call Apple or Google, and it does not treat that failure as a delivered push.

Enrollment's `credential_source` is `tinyweb` by default (or `override` in the lab path). That field is a label, not a secret.

## Operator setup

1. Install (default on): `install-tinyweb.sh` runs `install-push.sh` when `TWS_PUSH_ENABLE=1`. That script calls the hook `configure-push-credentials.sh --write-sygnal`.
2. Inject the secrets in the table above (environment or `/etc/tinywebstack/secrets/push/`).
3. Re-run: `sudo bash /opt/tinywebstack/vm/install-push.sh <main-domain>` so systemd switches off the refusing stub and onto Sygnal. Re-run family dashboard install (or `setup_family_dashboard_perms.py`) so `push.<domain>/` is a **visitors** SSO permission (no login redirect).
4. **Production** (`TWS_MODE=production`) stops the push install when those secrets are missing, so the box does not come up as if Sygnal delivered. **Lab** (`TWS_MODE=lab`) still installs ntfy and the refusing stub. Set `TWS_PUSH_REQUIRE_OPERATOR_KEYS=1` to force the failure, or `=0` to allow the stub even in production. Skip the stack entirely with `TWS_PUSH_ENABLE=0`.

Check without writing: `sudo bash /opt/tinywebstack/vm/configure-push-credentials.sh` (exit 2 when secrets are missing).

### Lab/dev operator override

`TWS_PUSH_CREDENTIAL_SOURCE=override` (aliases `lab` and `dev`) reads operator-supplied files instead of the shared directory: `TWS_APNS_KEY_PATH` (default `/etc/tinywebstack/secrets/apns/AuthKey.p8`) and, if no explicit FCM file is set, `/etc/tinywebstack/secrets/fcm/service-account.json`. This is for a lab operator pointing at their own keys. It is not shown to a parent. Override still fails closed when the files or ids are missing, and the default APNs environment in this mode is `sandbox` unless `TWS_APNS_ENV` is set.

## Android distributors

The app uses the UnifiedPush Flutter connector. Families need a distributor — typically the **ntfy** Android app with server URL **`https://push.<domain>`** (not the main family domain). Embedded ntfy distributor in TinyWeb is optional follow-up work.

## Lab test

On a lab VM after deploying box changes:

```bash
./scripts/vm/remote-run.sh 192.168.122.18 install-push.sh family-b.family.test
# Re-apply dashboard nginx + permissions (same as install-tinyweb family dashboard step)
```

From `app/` (with `TW_HS`, `TW_CA_FILE`, `TW_TEST_PASSWORD`, etc.):

```bash
/tmp/labtest-push.sh lab_test/push_test.dart
```

## Synapse loopback

Snippet: `/etc/matrix-synapse/conf.d/tinywebstack-push.yaml`:

```yaml
ip_range_whitelist:
  - "127.0.0.1"
push:
  include_content: false
```

Pusher `data.url` uses `http://127.0.0.1:<port>/...` so Synapse never needs broad private-network whitelist entries.
