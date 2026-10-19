# flutter_rust_bridge codegen notes (tw_matrix_spike spike)

## matrix-sdk dependency choices

- `matrix-sdk = 0.19.1` with **default features** left on:
  - `e2e-encryption`, `automatic-room-key-forwarding`, `sqlite`, `rustls-aws-lc-rs` (`reqwest/rustls`).
- Custom lab CA: `Client::builder().add_root_certificates(vec![Certificate::from_pem(...)])` via `matrix_sdk::reqwest::Certificate` (not a direct `reqwest` crate dep).
- SQLite session store: `Client::builder().sqlite_store(path, None)` (no store passphrase).

## Codegen

- Command (from `spikes/flutter-matrix-bridge/`): `flutter_rust_bridge_codegen generate`
- First run after adding `api/matrix.rs` completed **without codegen errors** (~44s).
- Removed stale `lib/src/rust/api/simple.dart` after dropping `api/simple.rs` (analyze would fail until deleted or codegen re-run).

## API / type friction

| Area | What we did |
|------|-------------|
| Opaque session | `#[flutter_rust_bridge::frb(opaque)] pub struct MatrixSession` with hand-written DTOs (`RoomSummary`, `IncomingMessage`). |
| Streams | `start_sync` takes `StreamSink<IncomingMessage>`; Dart gets `Stream<IncomingMessage>` via `session.startSync()`. |
| `StreamSink` import | Use `crate::frb_generated::StreamSink`, not `flutter_rust_bridge::StreamSink`. |
| matrix-sdk in handlers | `SyncRoomMessageEvent` is a `SyncMessageLikeEvent` wrapper — use `ev.as_original()` for body/sender/event_id. |
| Encryption metadata | Handler arg type: `matrix_sdk::deserialized_responses::EncryptionInfo`. |
| `user_id()` | Sync Rust method became `Future<String>` on Dart (`userId()`). |

## `cargo build` errors hit (and fixes)

1. **`StreamSink` not in `flutter_rust_bridge` root** → `use crate::frb_generated::StreamSink`.
2. **`reqwest::Certificate` unresolved** → `use matrix_sdk::reqwest::Certificate`.
3. **`matrix_sdk_base::EncryptionInfo`** → `matrix_sdk::deserialized_responses::EncryptionInfo`.
4. **Room name from state event** → use `room.name()` instead of raw state struct.
5. **`active_members_count` is `u64`** → cast to `u32` for FRB struct field.
6. **`SyncRoomMessageEvent` fields** → `as_original()` + methods `sender()` / `event_id()` on wrong type — use original event fields.
7. **`ev.membership() == MembershipState::Invite`** → dereference: `*ev.membership() == ...`.
8. **`stop_sync` drain on temporary mutex guard** → bind guard, then `drain`.

## Tokio / async runtime

- matrix-sdk uses tokio internally; FRB 2.13 default async handler worked for `login`, `sync_once`, etc. without panics in this spike.
- Added a **global `OnceLock<tokio::runtime::Runtime>`** (multi-thread, `Runtime::new()`) for:
  - `init_app()` warm-up
  - **background sync loop** in `start_sync` via `runtime().spawn(...)` (sync FRB entrypoint).
- Did **not** need `block_on` inside async FRB methods after making `build_client` fully async (avoid nested runtime deadlock).

## Runtime / test observations

- Loading `.so` in tests: `RustLib.init(externalLibrary: ExternalLibrary.open(TW_LIB))`.
- After `stop_sync`, FRB may log `Fail to post message to Dart` once handlers are torn down — harmless in one-shot tests.
- **Encrypted room create** on lab Synapse: `403 M_FORBIDDEN` / “event is not allowed in this context” when adding `m.room.encryption` initial state (even with `TrustedPrivateChat`). Unencrypted path is fully green; encrypted case is caught and reported in the test.
