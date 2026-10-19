# TinyWeb app (Flutter)

Stage 1 shell: enroll against your family box, home shortcuts, and **in-app Matrix chat** (Rust `matrix-sdk` facade via `tinyweb_core`).

## What Stage 1 includes

- QR / manual enrollment (`tinyweb://enroll`, one-time code, or username + password)
- Discovery via `/.well-known/tinywebstack-family.json`
- Secure storage of the enrollment bundle (Keychain / Keystore)
- Home: greeting, quiet-hours banner, shortcuts (parents: **Family controls** tile)
- **Calendar:** CalDAV tab — upcoming events from Nextcloud (shared + personal calendars); create/edit/delete; invite family members; accept/decline invites (credentials from enrollment)
- **Events:** Mobilizon tab — upcoming family and federated **PUBLIC** events; detail + join/leave RSVP; parents can create events (password enrollment issues Mobilizon GraphQL tokens). Kids without the dashboard **Events** toggle do not see the tab.
- **Kids:** background location publish to your box’s OwnTracks Recorder (no OwnTracks app); status card on Home; one-time explainer after enroll
- **Parents:** **Home | Calendar | Events | Locations | Family | Chat** — Locations tab lists each kid’s last fix and 24 h track points (no map yet); **Family** tab lists members (roles, enrolled phones), add/remove accounts, reset passwords, one-time enroll QR/codes, household invites, and per-kid chat allowlists, quiet hours, and Events access (`GET/PUT /family/permissions/{user}` with the dashboard bearer token)
- **Kids (events enabled):** **Home | Calendar | Events | Chat**
- **Kids (events disabled):** **Home | Calendar | Chat**
- Bottom nav chat: family Matrix chat in-app (no Element X)
- Chat: **end-to-end encrypted** room list, timelines, send, new DM, live sync when the app is foregrounded
- Recovery key setup after enroll (or when upgrading an older install)

## Development (spark / linux-arm64)

```bash
source ~/.cargo/env
export PATH=$HOME/sdk/flutter/bin:$PATH ANDROID_HOME=$HOME/sdk/android

cd app
flutter pub get
flutter test
flutter analyze
cd rust && cargo build --release
```

### Lab Matrix bridge test (optional)

Against the lab Synapse (skipped unless `TW_HS` is set):

```bash
source ~/.cargo/env
export TW_HS=https://family-b.family.test
export TW_CA_FILE=$HOME/.tinywebstack-secrets/lab-ca/lab-ca.crt.pem
export TW_TEST_PASSWORD=...   # lab password from your secrets store
export TW_LIB=$PWD/rust/target/release/libtinyweb_core.so
# On spark (no /etc/hosts for every lab subdomain), point lab HTTPS at the box IP:
export TW_RESOLVE_IP=192.168.x.x   # optional; lab_test/lab_env.dart only
cd app
flutter test lab_test/chat_bridge_test.dart
flutter test lab_test/e2ee_bridge_test.dart
# Or both (serial — see lab_test/dart_test.yaml):
flutter test lab_test/
```

Lab tests in `lab_test/` run **one at a time** (`dart_test.yaml` sets `concurrency: 1`) because they use the same lab accounts and `e2ee_bridge_test` resets cross-signing identity.

### Debug APK on spark

Google ships no linux-arm64 NDK, aapt2 or Android `gen_snapshot`, so **release APKs and iOS builds come from CI** (`.github/workflows/app.yml`). On spark, `flutter build apk --debug --target-platform android-arm64` works (about 190 s cold) once these user-space swaps are in place under `~/sdk/android`:

- `ndk/28.2.13676358` is the unofficial arm64 NDK r28c build (HomuHomu833/android-ndk-custom, sha256-checked). It matches Flutter's default `ndkVersion`, so plugins like `jni` and `mobile_scanner` find it too.
- `cmake/3.22.1/bin/{cmake,ctest,cpack,ninja}` are symlinks to arm64 binaries (system cmake 3.28, `uv tool install ninja`).
- `build-tools/36.0.0/{aapt2,aapt,zipalign,…}` and `platform-tools/adb` are arm64 static builds (lzhiyong/android-sdk-tools 35.0.2). `~/.gradle/gradle.properties` sets `android.aapt2FromMavenOverride` to that aapt2.

`-Ptinyweb.ndkVersion=<ver>` still overrides the app module's NDK if needed. CI uses Flutter's default.

## Location sharing

Kids enrolled on a family box receive OwnTracks HTTP publish credentials in the enrollment bundle. The app posts OwnTracks JSON to `/recorder/pub` with basic auth (throttled, queued offline up to 7 days). Parents read `GET /family/api/locations` and per-kid tracks; kids cannot open the Locations tab.

| OS | Behaviour |
|----|-----------|
| **Android** | Foreground service with a persistent notification (“TinyWeb is sharing your location with your family”); permissions: fine → background (“Allow all the time”) → notifications on Android 13+. |
| **iOS** | Significant-location changes plus a ~150 m circular region re-armed on exit (not continuous GPS); permissions: When In Use → Always; background location indicator shown. |

Battery: iOS defaults to low-power significant-change + region monitoring; Android uses geolocator with distance filter. Tuning iOS region radius is deferred.

**Deferred:** in-app family map (needs self-hosted tiles — public OSM would leak viewport to a third party); parent pause/resume of kid sharing.

Lab: `flutter test lab_test/location_publish_test.dart` (requires `TW_HS`, `TW_CA_FILE`, `TW_TEST_PASSWORD`; optional `TW_KID_USER` / `TW_PARENT_USER`, default `kid` / `parent`). Runs serially with other `lab_test/` tests.

Lab calendar: `flutter test lab_test/calendar_caldav_test.dart` (same env vars) — parent creates on `tws-family`, kid accepts invite.

Lab events: `flutter test lab_test/events_mobilizon_test.dart` (same env vars) — parent creates a PUBLIC Mobilizon event on the lab box; kid RSVPs.

Lab kid controls: `flutter test lab_test/kid_controls_test.dart` (same env vars) — parent toggles kid Events and quiet hours via permissions API, then restores.

Lab members admin: `flutter test lab_test/members_admin_test.dart` (same env vars) — parent creates/deletes a throwaway kid, enroll code, password reset, and household invite.

## Calendar (CalDAV)

The app uses a small in-tree CalDAV client (`PROPFIND`, `REPORT calendar-query`, `PUT`/`DELETE` with ETags) and ICS parse/serialize against `TWS_CALDAV_ROOT`. Nextcloud app passwords are issued in the enrollment bundle (`caldav`); re-enroll if calendar credentials are missing on an older install.

## Events (Mobilizon)

GraphQL client in `lib/src/events/` talks to `mobilizon.<domain>/api` with the `mobilizon` section from password enrollment (`access_token`, `api_url`). One-time **code** enrollment does not mint Mobilizon tokens — use password enroll or re-enroll for Events. New events default to **PUBLIC** for federation ([EVENTS.md](../docs/EVENTS.md)).

## Lab TLS

Lab family boxes use a **private CA**. Install the lab CA on a physical device for HTTPS enrollment — the app does **not** disable TLS verification. Pass the lab CA PEM into the Matrix Rust facade when testing on the host (`TW_CA_FILE` above).

### Lab DNS on spark (`TW_RESOLVE_IP`)

Some lab hostnames (e.g. `nextcloud.family-b.family.test`) are not in `/etc/hosts` on spark. Lab tests only: set `TW_RESOLVE_IP` to your family box IP before `flutter test lab_test/…`. Each `lab_test/*.dart` calls `installLabTestHttpOverrides()` from `lab_test/lab_env.dart`, which installs `HttpOverrides` and wires `lib/src/api/tls_http_client.dart` so Dart `HttpClient` still uses the original URL host for SNI/`Host`, verifies TLS with `TW_CA_FILE`, but opens TCP to `TW_RESOLVE_IP` for any host under the `TW_HS` hostname (via `connectionFactory`). Production app code in `lib/` is unchanged. Matrix bridge tests still use Rust’s own resolver for Synapse unless that host is also covered by your DNS setup.

## Layout

- `lib/` — Dart UI and HTTP clients
- `lib/src/chat/` — in-app chat UI and `ChatService`
- `lib/src/calendar/` — CalDAV client, ICS, Calendar tab UI
- `lib/src/events/` — Mobilizon GraphQL, Events tab UI
- `lib/src/location/` — OwnTracks publish, background service, parent Locations UI
- `rust/` — `tinyweb_core` Matrix facade (frb 2.13.0, cargokit)
- `lab_test/` — optional host-side Matrix bridge tests
- `assets/brand/` — vendored TinyWeb logos

## End-to-end encryption

Stage 1 chat uses Matrix **Megolm** (`m.megolm.v1.aes-sha2`). The Rust `tinyweb_core` bridge (`matrix-sdk` 0.19.1) stores crypto state in **SQLite** with a random device passphrase in secure storage.

**Included in this app**

- Encrypted DMs and rooms (`m.room.encryption` on create; server also defaults rooms to encrypted)
- Secret storage + key backup via `setup_recovery` / `recover` (recovery key shown once after enroll)
- Decrypted timelines; undecryptable events show “Unable to decrypt this message”
- Lock icon on encrypted rooms; recovery-key banner when the user skipped recovery

**Deferred**

- Interactive emoji/SAS verification of other users’ devices
- Parent “oversight” of a kid’s ciphertext on the server — parents can read a kid’s chats only on the kid’s unlocked device for now

## Verified

Last checked on spark (linux-arm64), 2026-10-18:

- `flutter test` — unit/widget tests passed (Matrix UI uses `FakeChatService`, no native lib)
- `flutter analyze` — no issues
- `cargo build --release` in `rust/` — OK (~90 s)
- `flutter build apk --debug --target-platform android-arm64` — OK (~78 s warm)
- Lab `lab_test/chat_bridge_test.dart` and `lab_test/e2ee_bridge_test.dart` (parent/kid, `TW_HS` / `TW_CA_FILE` / `TW_LIB` / `TW_TEST_PASSWORD`) — each passed alone; `flutter test lab_test/` passed serially (~chat 30–90s, e2ee ~1m37s)

## CI release builds (`.github/workflows/app.yml`)

On every PR or push that touches `app/`, CI runs `flutter analyze` and `flutter test`. It then builds:
- **Android** on ubuntu x86_64: split-per-ABI release APKs plus an AAB, uploaded as the `tinyweb-android` artifact.
- **iOS** on macOS: an **unsigned** IPA, uploaded as the `tinyweb-ios-unsigned` artifact.

Rust (`tinyweb_core`) is compiled by cargokit inside each build.

**Secrets William needs to add** (GitHub → Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` (create with `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`). Keep the keystore safe offline; losing it locks the Play listing. |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | The values used above. |
| `APPLE_TEAM_ID`, `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `APP_STORE_CONNECT_API_KEY_ID` / `_ISSUER_ID` / `_P8_BASE64` | iOS signing and TestFlight upload, from William's Apple developer account (bundle id `win.tinyweb.tinyweb`). Not used yet; the iOS signing step lands once these exist. |

Without the Android secrets, release builds are signed with the debug key, which is fine for sideload testing but not for Play. Google Play account ownership is still to be decided; F-Droid is open.
