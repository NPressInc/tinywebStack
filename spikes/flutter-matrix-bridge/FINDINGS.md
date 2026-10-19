# Flutter ↔ matrix-rust-sdk spike: findings

Date: 2026-10-18 · Host: spark (aarch64 Ubuntu 24.04, 20 cores, headless, no sudo)
Stack tested: Flutter 3.47.7 / Dart 3.13.5 · flutter_rust_bridge (frb) 2.13.0 (cargokit backend) · matrix-sdk 0.19.1 (sqlite store, E2EE, rustls) · Rust 1.99.1

## Recommendation

**Flutter is OK.** The bridge, which was the risk we were worried about, works. A hand-written Rust facade of about 375 lines, exposed through frb, ran login, sync (normal and native sliding sync), listing rooms, creating rooms, sending, and streaming received messages back to Dart. This included **E2EE (Megolm) rooms**. It worked on the first attempt, with no frb codegen errors. Messages arrived 70–225 ms after sending. Kotlin Multiplatform is not needed as a fallback for this reason.

The real costs are in the build tooling and in maintenance, not in the bridge:
1. **Release builds can't be made on spark.** Spark is an arm64 Linux machine. Google ships no linux-arm64 NDK or aapt2, and Flutter ships no linux-arm64 `gen_snapshot` for Android. Release APKs need an x86_64 Linux or macOS machine, or CI. iOS needs a Mac or macOS CI whichever stack we pick.
2. **The Rust library is large.** Without size tuning it is +44 MB per ABI. With size tuning it is **+12.1 MB uncompressed and about 6.3 MB compressed** per ABI, which is acceptable.
3. **We own the facade.** matrix-sdk is 0.x and its API breaks between minor versions. Keep the Dart-facing API small and stable, and pin the matrix-sdk and frb versions.

## What was proven (all automated, `test/matrix_bridge_test.dart`)

| Step | Lab tws-family-b (TinyWeb Synapse) | Stock Synapse 1.163.0 (docker on spark) |
|---|---|---|
| Password login, sqlite store, custom lab CA | ✅ 761–840 ms for two logins | ✅ ~850 ms |
| Normal sync (`sync_once`) | ✅ 357–397 ms (bob has 21 rooms) | ✅ 207–251 ms |
| Native sliding sync (MSC4186) | ✅ advertised; one room-list sync OK | ✅ |
| List rooms | ✅ | ✅ |
| Create room + invite, auto-join in the sync loop | ✅ | ✅ |
| Send text, received by the other user through a Rust→Dart `Stream` | ✅ ping 131–140 ms, pong 70–88 ms | ✅ 137–225 / 70–117 ms |
| **Encrypted room** send/receive (`wasEncrypted=true`) | ⛔ 403: the family module rejects `m.room.encryption` **by design** (PLAN P3.8, E2EE off in v1) | ✅ ping 194–224 ms, pong 90–101 ms |
| Debug APK (`flutter build apk --debug`, arm64-v8a) | ✅ built (with the workarounds below) | – |
| Release APK | ❌ blocked on spark's arm64 host (no `gen_snapshot`). Not a Flutter/Rust problem | – |
| Rust `.so` cross-compiled for `aarch64-linux-android` (release) | ✅ with cargo-ndk 4.1.2 | – |
| iOS | not possible on Linux (needs Xcode). frb + cargokit support iOS; unverified | – |

The size-optimized build (`lto=fat, opt-level=z, codegen-units=1, strip, panic=abort`) was re-run through the full test and passed, including E2EE.

## Numbers

| Metric | Value |
|---|---|
| Toolchain setup on a clean user account | ~5 min of downloads (rustup 6 s, Flutter clone and first run 2 m 23 s, frb codegen 21 s + cargo-ndk 9 s to compile, Android cmdline-tools/platform/build-tools 10 s, NDK 160 MB). Disk: Flutter 1.6 GB, Android SDK+NDK 2.1 GB |
| Scaffold (`flutter_rust_bridge_codegen create`) | 10 s |
| Spike code written by Cursor CLI (composer-2.5) | 6.3 min, working on the first run |
| `flutter_rust_bridge_codegen generate` after each Rust API change | 30–44 s (runs `cargo expand`); the slowest part of the edit loop |
| Rust lib, host release, cold / warm (touch facade) | 83 s / 19 s (389 crates) |
| Rust lib, Android arm64 release, cold, default / size-opt | 85 s / 128 s |
| First debug APK (Gradle + cargokit, arm64 + x86_64 Rust) | 206 s cold |
| `.so` arm64 Android, default release: raw / stripped / gzip | 72.3 / 44.4 / 17.1 MB |
| `.so` arm64 Android, size-opt: raw / gzip | **12.1 / 6.3 MB** |
| APK delta (estimate) | +12 MB installed and about +6 MB download per ABI, on top of a release Flutter app of roughly 8–10 MB (not measured here because the release build is blocked). Element X's official Android AAR is 100 MB across 4 ABIs, so this is the same order of size |
| Debug APK | 231 MB (unoptimized Rust for 2 ABIs plus a debug engine; not representative) |

## Pain points hit (and fixes)

1. **frb can't auto-translate matrix-sdk.** Async closures and `Stream` types fail to parse (frb issue #2486). *Fix:* use an opaque `MatrixSession` plus hand-written DTOs (`RoomSummary`, `IncomingMessage`). After that, codegen had **zero errors**. This is how real use would work anyway.
2. **Async runtime.** frb's default async handler drove matrix-sdk futures fine. The long-running sync loop needed a global tokio `Runtime` (`OnceLock`) and `runtime().spawn`. There are harmless `Fail to post message to Dart` logs after `stop_sync` closes the sink.
3. **Streams.** `StreamSink<T>` → Dart `Stream<T>` worked. It has to be imported from `crate::frb_generated`. Backpressure and cancellation weren't exercised. frb 2.14-beta fixes a hang in `StreamSubscription.cancel()` on idle sinks, so pick that up when it's stable.
4. **Android linking.** It failed with `unable to find library -lsqlite3`. *Fix:* matrix-sdk feature `bundled-sqlite`. `aws-lc-rs` (rustls) cross-compiled fine with the NDK.
5. **The arm64 build host** (spark-specific; it would hit KMP and native Android equally):
   - No official NDK → used the unofficial aarch64 NDK r30 build (HomuHomu833/android-ndk-custom), with `ndkVersion` pinned in `android/app/build.gradle.kts`.
   - AGP's Maven aapt2 is x86_64 → `android.aapt2FromMavenOverride` in `~/.gradle/gradle.properties`, pointing at an arm64 static aapt2 (lzhiyong/android-sdk-tools 35.0.2).
   - Release `gen_snapshot` is missing for linux-arm64 → **no workaround; use CI.**
6. The other 8 compile errors were about learning the matrix-sdk API (`as_original()`, `EncryptionInfo` path, `u64`→`u32` casts). Details are in NOTES-codegen.md.

## Maintenance concerns

- **matrix-sdk churn:** it is 0.x, and minors (about every 1–2 months) routinely break the API. Element X avoids this by tracking `matrix-sdk-ffi` (git, not crates.io) with roughly weekly releases. For us, a facade of about 400–1500 lines, pinned and updated deliberately each quarter, is manageable.
- **The real work is ahead:** a usable chat UI needs `matrix-sdk-ui` (`RoomListService`, `Timeline`, `SyncService`), which means more facade surface. Mirroring the subset that `matrix-sdk-ffi` exposes is a good template.
- **frb:** a single maintainer with very active releases (2.13.0 in Aug 2026, 2.14-beta in Sep 2026) and about 1.8M recent downloads. The runtime crate and codegen must match exactly (`=2.13.0`).
- **Toolchain:** the Flutter, Gradle/AGP, NDK, and Rust upgrades are now coupled. cargokit is the stable integration; native-assets is the newer path.

## Alternatives checked (research only)

- **Kotlin Multiplatform + official bindings:** `org.matrix.rustcomponents:sdk-android` (26.10.15, 16 Oct 2026; uniffi/JNA; high-level ffi with timeline, room list, and sync service) and `matrix-rust-components-swift` are **Android-only and Swift-only**, not KMP artifacts. Shared Kotlin for iOS would need community uniffi→KMP generators (Gobley, Ubique uniffi-kotlin-multiplatform-bindings), so the same "glue we own" risk returns. Otherwise each platform calls its own binding, and UI and Matrix code get written twice. The upside is that there's no facade to write for Android. The downside is two codebases or Compose Multiplatform on iOS, and the same arm64-host Android limits.
- **famedly `matrix` Dart SDK** (14.1.0, 16 Oct 2026; FluffyChat; pure Dart + `flutter_vodozemac` via frb for crypto): the lowest-friction Flutter route, with no facade and no 12 MB library. Caveats: it is **AGPL-3.0** (compatible with an open-source TinyWeb, but it binds us), and its crypto and sliding sync are less complete than matrix-rust-sdk. It is a good backup if the Rust facade ever becomes a burden.
- `moca_matrix_sdk` (frb wrapper on pub.dev): unmaintained, last published about 21 months ago. Not usable.

## Suggested next steps if we go with Flutter

1. Set up GitHub Actions (ubuntu-x86_64 for the APK, macOS for the IPA) as the release build path. spark stays the dev and test box, with debug APKs and host tests.
2. Grow the facade around `matrix-sdk-ui` (room list and timeline streams) behind a small, versioned Dart API.
3. Add the size-optimized `[profile.release]` to the real app crate. Keep `panic=abort` only after checking frb's panic-abort notes.
