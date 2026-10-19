# Push notifications (privacy-first)

TinyWeb wakes phones for new Matrix messages **without putting message text in push payloads**. The app fetches and decrypts on device, then shows a local notification.

## Architecture

```
Matrix client (app)
    |  POST /pushers/set  (format=event_id_only, pushkey=topic|APNs token)
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

Public HTTPS: `https://push.<main-domain>/` (nginx → loopback services).

- **Android (primary):** UnifiedPush via self-hosted **ntfy** on the box. Matrix uses ntfy’s `/_matrix/push/v1/notify` gateway. `pushkey` is an unguessable per-device topic; ntfy is locked down (`auth-default-access: deny-all`); Synapse reaches ntfy on `127.0.0.1` only (`ip_range_whitelist`).
- **iOS:** **Sygnal** on loopback with APNs `default_payload` generic title/body (no room/sender/content). Optional Notification Service Extension can fetch later; not required for v1.
- **Optional FCM:** Sygnal app entry for `<applicationId>.android` when a service account JSON is present.

## Privacy model

| Party | Sees |
|--------|------|
| Apple / Google (if FCM enabled) | Device token, timing, generic alert — not message bodies from TinyWeb payloads |
| Push gateway (ntfy/Sygnal on your box) | `event_id`, `room_id`, counts — no plaintext message |
| App | Full message after authenticated fetch from your box |

Enrollment returns only public gateway URLs and app IDs — **no secrets**.

## Operator setup

1. Install (default on): `install-tinyweb.sh` runs `install-push.sh` when `TWS_PUSH_ENABLE=1`.
2. **APNs (William):** Place `AuthKey_XXXX.p8` at `/etc/tinywebstack/secrets/apns/AuthKey.p8` and set in `tinyweb.env`:
   - `TWS_APNS_KEY_ID`
   - `TWS_APNS_TEAM_ID`
   - `TWS_APNS_BUNDLE_ID` (default `win.tinyweb.tinyweb`)
   - `TWS_APNS_ENV` (`sandbox` or `production`)
3. Re-run: `sudo bash /opt/tinywebstack/vm/install-push.sh <main-domain>`
4. **FCM (optional):** `TWS_FCM_SERVICE_ACCOUNT_FILE=/etc/tinywebstack/secrets/fcm/service-account.json` and enable in Sygnal config via re-run installer.

Disable push stack: `TWS_PUSH_ENABLE=0` before install.

## Android distributors

The app uses the UnifiedPush Flutter connector. Families need a distributor — typically the **ntfy** Android app pointed at `https://push.<domain>`. Embedded FCM distributor is optional future work.

## Lab test

On a lab VM after deploying box changes:

```bash
./scripts/vm/remote-run.sh 192.168.122.18 install-push.sh family-b.family.test
```

From `app/` (with `TW_HS`, `TW_CA_FILE`, `TW_TEST_PASSWORD`, etc.):

```bash
flutter test lab_test/push_test.dart
```

## Synapse loopback

Snippet: `/etc/matrix-synapse/conf.d/tinywebstack-push.yaml`:

```yaml
ip_range_whitelist:
  - "127.0.0.1"
```

Pusher `data.url` uses `http://127.0.0.1:<port>/...` so Synapse never needs broad private-network whitelist entries.
