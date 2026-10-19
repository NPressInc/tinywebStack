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
- **iOS:** **Sygnal** on loopback with APNs `default_payload` generic title/body (no room/sender/content). Until `AuthKey.p8` is installed, a **loopback health stub** listens on the Sygnal port (Sygnal itself requires at least one app entry). Re-run `install-push.sh` after adding APNs keys to start real Sygnal.
- **Optional FCM:** Sygnal app entry for `<applicationId>.android` when a service account JSON is present.

## Privacy model

| Party | Sees |
|--------|------|
| Apple / Google (if FCM enabled) | Device token, timing, generic alert — not message bodies from TinyWeb payloads |
| Push gateway (ntfy/Sygnal on your box) | `event_id`, `room_id`, counts — no plaintext message |
| App | Full message after authenticated fetch from your box |

Enrollment returns only public gateway URLs and app IDs — **no secrets**.

Synapse is configured with `push.include_content: false` and apps always register `event_id_only` pushers. The `tinywebstack_family` module includes `pusher_policy.py` documenting the required shape, but **Synapse has no module hook to reject rogue pushers** — enforcement is: app + Synapse config + lab test.

## Operator setup

1. Install (default on): `install-tinyweb.sh` runs `install-push.sh` when `TWS_PUSH_ENABLE=1`.
2. **APNs (William):** Place `AuthKey_XXXX.p8` at `/etc/tinywebstack/secrets/apns/AuthKey.p8` and set in `tinyweb.env`:
   - `TWS_APNS_KEY_ID`
   - `TWS_APNS_TEAM_ID`
   - `TWS_APNS_BUNDLE_ID` (default `win.tinyweb.tinyweb`)
   - `TWS_APNS_ENV` (`sandbox` or `production`)
3. Re-run: `sudo bash /opt/tinywebstack/vm/install-push.sh <main-domain>` and re-run family dashboard install (or `setup_family_dashboard_perms.py`) so `push.<domain>/` is a **visitors** SSO permission (no login redirect).
4. **FCM (optional):** `TWS_FCM_SERVICE_ACCOUNT_FILE=/etc/tinywebstack/secrets/fcm/service-account.json` and enable in Sygnal config via re-run installer.

Disable push stack: `TWS_PUSH_ENABLE=0` before install.

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
