# TinyWeb app (Flutter)

Stage 1 shell: enroll against your family box, home shortcuts, and **in-app Matrix chat** (Rust `matrix-sdk` facade via `tinyweb_core`).

## What Stage 1 includes

- QR / manual enrollment (`tinyweb://enroll`, one-time code, or username + password)
- Discovery via `/.well-known/tinywebstack-family.json`
- Secure storage of the enrollment bundle (Keychain / Keystore)
- Home: greeting, quiet-hours banner, tiles (Calendar / Events / map / controls show “Coming soon”)
- Bottom nav: **Home | Chat** — family Matrix chat in-app (no Element X)
- Chat: room list, timelines, send, new DM, live sync when the app is foregrounded

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
cd app
flutter test integration_test_host/chat_bridge_test.dart
```

### Debug APK on spark

Google ships no linux-arm64 NDK, aapt2 or Android `gen_snapshot`, so **release APKs and iOS builds come from CI** (`.github/workflows/app.yml`). On spark, `flutter build apk --debug --target-platform android-arm64` works (about 190 s cold) once these user-space swaps are in place under `~/sdk/android`:

- `ndk/28.2.13676358` is the unofficial arm64 NDK r28c build (HomuHomu833/android-ndk-custom, sha256-checked). It matches Flutter's default `ndkVersion`, so plugins like `jni` and `mobile_scanner` find it too.
- `cmake/3.22.1/bin/{cmake,ctest,cpack,ninja}` are symlinks to arm64 binaries (system cmake 3.28, `uv tool install ninja`).
- `build-tools/36.0.0/{aapt2,aapt,zipalign,…}` and `platform-tools/adb` are arm64 static builds (lzhiyong/android-sdk-tools 35.0.2). `~/.gradle/gradle.properties` sets `android.aapt2FromMavenOverride` to that aapt2.

`-Ptinyweb.ndkVersion=<ver>` still overrides the app module's NDK if needed. CI uses Flutter's default.

## Lab TLS

Lab family boxes use a **private CA**. Install the lab CA on a physical device for HTTPS enrollment — the app does **not** disable TLS verification. Pass the lab CA PEM into the Matrix Rust facade when testing on the host (`TW_CA_FILE` above).

## Layout

- `lib/` — Dart UI and HTTP clients
- `lib/src/chat/` — in-app chat UI and `ChatService`
- `rust/` — `tinyweb_core` Matrix facade (frb 2.13.0, cargokit)
- `integration_test_host/` — optional host-side Matrix bridge tests
- `assets/brand/` — vendored TinyWeb logos

## Verified

- `flutter test` — 23 widget/unit tests passed (host; no native lib loaded in UI tests)
- `flutter analyze` — no issues
- `cargo build --release` in `rust/` — OK
- `flutter build apk --debug --target-platform android-arm64` — OK (~73 s warm)
- Lab `integration_test_host/chat_bridge_test.dart` with `TW_HS` / `TW_CA_FILE` / `TW_LIB` / `TW_TEST_PASSWORD` — `chat bridge e2e against Synapse` passed (~5 s; source lives under `integration_test_host/`)
