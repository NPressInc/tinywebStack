# TinyWeb mobile app plan

**App code:** [`app/`](../app/) (Flutter + `tinyweb_core` Rust crate). **Chat is in-app and end-to-end encrypted from Stage 1** (no Element X hand-off).

One **TinyWeb** app (iOS + Android) that talks only to **the family’s own box** — no TinyWeb cloud, no third-party accounts. The existing **parent dashboard** (`/family/`, [FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md)) stays the admin and provisioning surface; the app is the everyday surface for parents and kids.

**Grounding:** [PLAN.md](../PLAN.md), [PHILOSOPHY.md](PHILOSOPHY.md), [FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md), [CALENDAR.md](CALENDAR.md), [EVENTS.md](EVENTS.md), [FAMILY_MODULE.md](FAMILY_MODULE.md), [FAMILY_INVITE.md](FAMILY_INVITE.md), [TINYWEB_BRANDING.md](TINYWEB_BRANDING.md). Dashboard code: `family/dashboard/tinywebstack_dashboard/`.

---

## 1. Goal and principles

| Principle | What it means |
|-----------|----------------|
| **One login** | After enrollment, the app uses device-stored credentials; parents do not juggle five apps’ logins. |
| **Own box only** | Base URL is `https://<main-domain>` from QR or manual entry; discovery via `/.well-known/tinywebstack-family.json` ([`app.py`](../family/dashboard/tinywebstack_dashboard/app.py)). No central TinyWeb SaaS. |
| **Kid-safe defaults** | Same server rules as today: `tinywebstack_family` Synapse module + `/etc/tinywebstack/permissions.db` ([FAMILY_MODULE.md](FAMILY_MODULE.md), `family/permissions/`). |
| **Data stays on the box** | Chat, calendar, events, location, and dashboard APIs hit the home server over TLS. **Exception:** push notifications (see §6) may use Apple/Google/UnifiedPush infrastructure with **content-free** payloads. |
| **Open source** | App and server changes in this repo; families can self-host and audit. |
| **Dashboard = admin, app = daily** | Members, passwords, invite links, QR for legacy clients remain on the dashboard; the app consumes JSON APIs where they exist or backends directly after enrollment. |

Branding follows [tinyweb.win](https://tinyweb.win) and vendored assets in `brand/` ([TINYWEB_BRANDING.md](TINYWEB_BRANDING.md)).

---

## 2. Recommended client stack

**Decision (2026-10-18): Flutter (Dart)**, with `matrix-rust-sdk` reached through a `flutter_rust_bridge` facade. Release builds come from CI. Approved by William after the bridge spike ([spikes/flutter-matrix-bridge/FINDINGS.md](../spikes/flutter-matrix-bridge/FINDINGS.md)).

**Spike results (frb 2.13, matrix-sdk 0.19.1):**
- Proven from a Dart test against lab Synapse (tws-family-b) and stock Synapse: login, normal sync, native sliding sync (MSC4186), room list, create, send, and receive through a Rust→Dart stream (70–225 ms). E2EE rooms work on stock Synapse, and the family module now allows them (Stage 1 is E2EE).
- The size-optimized Rust `.so` adds about 12 MB uncompressed (about 6 MB download) per ABI.
- A cold Rust build takes about 85 s, a warm one about 19 s. Codegen takes 30–44 s per API change.
- **ARM64 build-host constraint:** spark (linux-arm64) can build debug APKs only, using an unofficial arm64 NDK and aapt2. Google ships no linux-arm64 NDK or aapt2, and Flutter ships no linux-arm64 Android `gen_snapshot`. **Release APKs are built on GitHub Actions ubuntu x86_64 runners and iOS on macOS runners** (`.github/workflows/app.yml`). Spark remains the dev and test box.
- KMP was rejected: the official Kotlin and Swift bindings are separate Android-only and Swift-only artifacts, not KMP.

| Option | Pros | Cons |
|--------|------|------|
| **Flutter** | One UI codebase for iOS + Android with consistent TinyWeb branding; mature map (`flutter_map`) and calendar widgets; good Rust FFI tooling (`flutter_rust_bridge`) for Matrix. | Matrix needs a **custom bridge** to `matrix-rust-sdk` (see risk §8). |
| **React Native** | Large ecosystem. (Element X itself is native Swift/Kotlin, so there is no RN Matrix client to reuse.) | Heavy native bridging for `matrix-rust-sdk`; two platform toolchains for anything non-JS. |
| **Kotlin Multiplatform (KMP)** | **First-class** `matrix-rust-sdk` Kotlin bindings (same path Element X uses via UniFFI). | iOS UI still separate unless Compose Multiplatform (less mature on iOS); two UI codepaths or immature MP. |

**Matrix:** Use **`matrix-rust-sdk`** via official FFI (UniFFI → Kotlin/Swift, as Element X does). On Flutter, wrap with **`flutter_rust_bridge`** or generated UniFFI bindings in a thin Rust crate — The spike has **proven** sync, send and receive against lab Synapse (above). Keep the Dart-facing API small, and pin `matrix-sdk` and `flutter_rust_bridge` exactly.

**CalDAV:** Plain HTTP client (`PROPFIND`, `REPORT`, `PUT`, `DELETE`) against Nextcloud’s CalDAV root (`TWS_CALDAV_ROOT`, e.g. `https://nextcloud.<domain>/nextcloud/remote.php/dav` — [CALENDAR.md](CALENDAR.md), [`calendar_setup.py`](../family/dashboard/tinywebstack_dashboard/calendar_setup.py)).

**Maps (parents):** `flutter_map` + raster tiles. Default: OSM or other public tile CDN — **tile requests leak approximate map viewport to the tile provider**; document in app settings; optional later: self-hosted tile server on the box.

---

## 3. Authentication and enrollment

Native apps cannot use YunoHost’s **SSOwat cookie** portal flow. Today each backend uses a different mechanism; the dashboard has **no bearer-token auth** (only `YNH_USER` from SSOwat — [`auth.py`](../family/dashboard/tinywebstack_dashboard/auth.py)).

### Current mechanisms (from repo)

| Backend | Current auth | App gap |
|---------|----------------|---------|
| **YunoHost SSO** | Browser cookie via SSOwat portal ([FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md)) | Not usable in native app without embedded WebView login (undesired). |
| **Family dashboard** | `YNH_USER` header; `require_parent()` for HTML routes; CSRF on forms | No token API for app; JSON routes still expect SSO header. |
| **Matrix (Synapse)** | Lab/scripts use **`m.login.password`** with YunoHost LDAP password ([`verify-federation-e2e.sh`](../scripts/spark/verify-federation-e2e.sh), [`synapse-admin-token.sh`](../scripts/lib/synapse-admin-token.sh)); Element may also use SSO in browser | App needs **access token + device id** stored on device. |
| **Nextcloud CalDAV** | **HTTP Basic** with family password; `visitors` on `nextcloud.main` for DAV without SSO cookie ([CALENDAR.md](CALENDAR.md), [`davx5_login_hint()`](../family/dashboard/tinywebstack_dashboard/calendar_setup.py)) | Prefer **per-device app password** minted at enrollment (not shared family password). |
| **Mobilizon** | Separate **LDAP login** via GraphQL `login` → `accessToken` / `refreshToken`; gated by LDAP group **`events-users`** ([EVENTS.md](EVENTS.md)) | App can call GraphQL with same username/password or enrolled tokens; SSO tile does not help the app. |
| **OwnTracks Recorder** | Kid **publish**: HTTP POST to `/recorder/pub` with basic auth from `/etc/tinywebstack/owntracks-kids.json` ([`owntracks_setup.py`](../family/dashboard/tinywebstack_dashboard/owntracks_setup.py), nginx in [`install-family-dashboard.sh`](../scripts/vm/install-family-dashboard.sh)); **read**: Recorder web/API behind YunoHost **`owntracks.main`** (parents only — [FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md) G4.2) | App needs Recorder API credentials or a dashboard proxy for parent map; kids keep publishing (Stage 1: still OwnTracks app). |

### Dashboard routes today (HTML vs JSON)

| Path (behind `https://<domain>/family/`) | Type | Auth |
|------------------------------------------|------|------|
| `/`, `/members/*`, `/kid/*`, `/invite/*`, `/calendar`, `/members/*/location` | HTML + forms | SSO + parents (`YNH_USER`) |
| `GET/PUT /permissions/{user}` | JSON | SSO; PUT parents only ([`permissions.py`](../family/dashboard/tinywebstack_dashboard/permissions.py)) |
| `GET/POST/DELETE /federation/domains` | JSON | SSO + parents ([`federation.py`](../family/dashboard/tinywebstack_dashboard/federation.py)) |
| `POST /api/invite/verify` | JSON | **Public** (also `https://<domain>/family/api/invite/verify`) |
| `GET /.well-known/tinywebstack-family.json` | JSON | **Public** (proxied at site root) |

Env knobs: `TWS_SERVER_NAME`, `TWS_CALDAV_ROOT`, `TWS_EVENTS_URL`, `TWS_LOCATION_URL`, `TWS_OWNTRACKS_KIDS_FILE`, `TWS_PERMISSIONS_DB` ([`app.py`](../family/dashboard/tinywebstack_dashboard/app.py), [`install-family-dashboard.sh`](../scripts/vm/install-family-dashboard.sh)).

### App enrollment (Stage 1 — built)

Single **provisioning** flow so families sign in once:

1. **Discover box:** Scan QR encoding `https://<main-domain>` (or read `/.well-known/tinywebstack-family.json` for `server_name`, `enroll_url`, `matrix_homeserver_url`, `caldav_root`, etc.).
2. **Enroll:** `POST /family/api/app/enroll` (public; rate-limited) with JSON:
   - **Password:** `{ "method": "password", "username", "password", "device_name", "platform": "android"|"ios"|"other" }` — Synapse `m.login.password` (+ optional Mobilizon GraphQL `login` when `TWS_EVENTS_URL` is set).
   - **Code:** `{ "method": "code", "code", "device_name", "platform" }` — parent mints code via dashboard or `POST /family/api/app/codes` (`{"username"}` → `{code, expires_at, qr_payload}`).
3. **Server** returns a **one-time JSON bundle** (`Cache-Control: no-store`): dashboard bearer `tws_…` (SHA-256 in `/etc/tinywebstack/app-devices.db`), CalDAV app password, OwnTracks (kids), Mobilizon tokens when password login succeeded, Matrix when password login succeeded.
4. **Code enrollment** also provisions a real Matrix device. The dashboard mints a 60-second HMAC ticket and logs in server-side through the family module's `org.tinywebstack.login_ticket` login type; the ticket never leaves the box ([FAMILY_MODULE.md](FAMILY_MODULE.md)). Mobilizon returns `password_required` for code enrollment.
5. App stores secrets in **Keychain / Keystore**; never logs them.

**Lifecycle (built):**

- `GET /family/api/app/devices` — parents see all devices; others see own (no token hashes).
- `POST /family/api/app/devices/{id}/revoke` — owner or parent; best-effort Matrix device + Nextcloud app-password delete via privileged helper.
- `GET /family/api/app/me` — profile, quiet hours (kids), `events_enabled`.
- `GET /family/api/members`, `GET /family/api/invites` — parents only.
- **Password reset** on the dashboard **revokes** all app devices for that user.

**Nginx / SSOwat:** New `/family/api/*` routes must accept `Authorization: Bearer <dashboard-token>` **without** SSO cookie, while browser `/family/` HTML stays SSO-only. Mirror pattern of public `/family/api/invite/verify` ([`install-family-dashboard.sh`](../scripts/vm/install-family-dashboard.sh) nginx snippets).

---

## 4. Per-module integration

| Module | API / protocol | App UX | Stage 1 |
|--------|----------------|--------|---------|
| **Home** | Dashboard bearer + well-known | Status, shortcuts, quiet-hours banner from `GET /permissions/{self}` | Read-only |
| **Calendar** | CalDAV on `TWS_CALDAV_ROOT` | Month/agenda; shared + personal calendars ([CALENDAR.md](CALENDAR.md)) | Read/write own events; accept/decline iTIP invites |
| **Events** | Mobilizon **GraphQL** at `mobilizon.<domain>` | List/detail, RSVP; show **PUBLIC** federated events ([EVENTS.md](EVENTS.md)) | Read + RSVP; **create event parents-only** (optional kids in stage 1.1) |
| **Location** | OwnTracks Recorder **HTTP API** (`/api/0/...`) for parents; publish `POST .../recorder/pub` | Parents: family map read-only; kids: no map | Parents read-only; kids still use **OwnTracks app** to publish |
| **Parent controls** | `GET/PUT /family/permissions/{user}`; federation JSON exists | Allowlists, quiet hours, events toggle — mirror dashboard kid edit | Parents: read/write via API; needs JSON for **members / invites** (proposed) |
| **Chat** | `matrix-rust-sdk` (via `tinyweb_core`, frb) + Synapse | In-app room list, timeline, send, new DM; show `M_FORBIDDEN` from the module as friendly copy; rooms are created **encrypted**; recovery key / key backup set up at enrollment | Read/write (**in-app from Stage 1**) |

---

## 5. Delivery stages and acceptance tests

Lab: two-family spark VMs ([test-nodes.md](test-nodes.md)); style checks like [`verify-calendar-e2e.sh`](../scripts/spark/verify-calendar-e2e.sh), [`verify-events-e2e.sh`](../scripts/spark/verify-events-e2e.sh), [`verify-federation-e2e.sh`](../scripts/spark/verify-federation-e2e.sh). Add **`scripts/spark/verify-tinyweb-app-stageN.sh`** as each stage lands.

### Stage 1 — Shell app (“everything” navigation)

**Deliverables:** Enrollment (proposed API or interim manual secret paste for dev), home, CalDAV calendar, Mobilizon events, parent location map, parent controls (permissions API), and **in-app chat** (matrix-rust-sdk: room list, timeline, send). Chat is **end-to-end encrypted**: sqlite crypto store, cross-signing and key backup, with a recovery key shown at enrollment so a new phone can read history. Parent-key oversight is deferred; parents read a kid's chats only on the kid's device for now. Native simplified sliding sync was confirmed on lab Synapse by the spike.

| Test | Pass criteria |
|------|----------------|
| Enroll parent on `family-a` | App stores credentials; `GET /family/permissions/parent` with bearer returns 200 (after server work) or SSO curl equivalent in CI |
| Kid enroll | Kid mode hides map and parent controls |
| Calendar | Create event on `tws-family`; visible in app; kid sees shared calendar per [verify-calendar-e2e.sh](../scripts/spark/verify-calendar-e2e.sh) semantics |
| Events | Parent RSVP on federated event; [verify-events-e2e.sh](../scripts/spark/verify-events-e2e.sh) still passes |
| Location | Parent sees kid trace from Recorder; kid account cannot open map UI |
| Chat | Room list and timeline load after enrollment (password or code); a sent message reaches the other member |
| Parent ↔ kid DM | Message delivered |
| Allowlist | Kid DM to non-allowlisted MXID fails with user-visible “not allowed” (server `M_FORBIDDEN`) |
| Quiet hours | Kid send denied during window (banner shown); parent can send |
| Federation DM | Cross-family allowlisted DM per [verify-federation-e2e.sh](../scripts/spark/verify-federation-e2e.sh) |
| Federation | Trusted-family events still appear; Matrix allowlist unchanged |

### Stage 2 — Calls and background location

**Deliverables:** Voice/video via **Element Call + LiveKit SFU** on box (MatrixRTC); in-app background location publishing (replaces OwnTracks app).

| Test | Pass criteria |
|------|----------------|
| Call | Parent and kid complete 1:1 call on LAN/lab TLS |
| Location | Kid phone publishes without OwnTracks app; parent map updates |

### Later

- Media (**Jellyfin**, **Immich**) from [PLAN.md](../PLAN.md).
- **Parent-key oversight** for kids' encrypted rooms ([FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md) P3.8, deferred).

---

## 6. Server-side changes (dashboard + nginx)

### JSON endpoints

| Endpoint | Status | Purpose |
|----------|--------|---------|
| `POST /family/api/app/enroll` | **Built** | One-time credential bundle (public) |
| `POST /family/api/app/codes` | **Built** | Parent: one-time enroll code + QR payload |
| `GET /family/api/app/me` | **Built** | Self profile + quiet hours |
| `GET /family/api/app/devices` | **Built** | List enrolled devices |
| `POST /family/api/app/devices/{id}/revoke` | **Built** | Revoke device |
| `GET /family/api/members` | **Built** | JSON member list |
| `GET /family/api/invites` | **Built** | Pending cross-family invites (no secrets) |
| `POST /family/api/members` | Proposed | Create member (wraps privileged helper) |
| `POST /family/api/members/{user}/reset-password` | Proposed | Parent reset (HTML exists today) |
| `GET/POST /family/api/invite/*` | Partial | `POST …/verify` built; create/redeem JSON TBD |
| `GET /family/api/location/locations` | Proposed | Parent-only Recorder proxy |

**Existing (keep):** `GET/PUT /family/permissions/{user}`, `/family/federation/domains`, public invite verify, well-known.

### Bearer auth alongside SSOwat

- FastAPI dependency: accept **either** `YNH_USER` (browser) **or** `Authorization: Bearer` (app) on `/family/api/*`.
- Nginx: location blocks for `/family/api/app/` with `proxy_set_header Remote-User ""` and no SSOwat redirect (same idea as invite verify).
- **CORS:** Not required for native apps; enable only if a web build exists — default deny.

### Push notifications

| Channel | Approach |
|---------|----------|
| **Matrix** | Self-hosted **Sygnal** on the box, or upstream-compatible gateway; register pusher per device. |
| **Android** | **ntfy** on box as UnifiedPush distributor (no Google dependency) where possible. |
| **iOS** | **APNs required** by Apple — payloads must be minimal (`event_id` / room id only); app fetches content from box over TLS. Cert/account held by **app publisher** (open question). |
| **Calendar / events** | Local notifications scheduled from CalDAV sync; Mobilizon push via GraphQL subscriptions or polling + unified push topic. |

**Privacy rule:** Notification body on vendor networks should not contain message text, location, or event titles — only opaque ids.

---

## 7. Kid mode vs parent mode

Same binary; **mode from LDAP groups** at enrollment (`parents` vs `kids` — `TWS_PARENTS_GROUP` / `TWS_KIDS_GROUP`).

| Surface | Parent | Kid |
|---------|--------|-----|
| Parent controls | Yes (`PUT /permissions/{kid}`) | Hidden |
| Location map | Yes | Hidden |
| Events tab | Yes | Only if `events_enabled` / `events-users` ([EVENTS.md](EVENTS.md)) |
| Chat contacts | Full (subject to Matrix policy) | UI reflects allowlist; **Synapse module enforces** |
| Quiet hours | N/A | Banner when active; server still blocks sends |
| Account / server | No multi-account; no “add homeserver” | Same |

**Principle:** The app **never** enforces safety alone; the box does ([PHILOSOPHY.md](PHILOSOPHY.md)).

---

## 8. Risks and open questions

| Topic | Notes |
|-------|--------|
| **Flutter ↔ matrix-rust-sdk** | **Resolved by spike** (Flutter chosen). Remaining cost: owning the facade as matrix-sdk 0.x changes its API. Pin versions and update deliberately. |
| **Release builds** | Spark is ARM64, so it can't build release Android artifacts. CI on x86_64 and macOS runners is the release path. |
| **App store publishing** | William owns the **Apple** developer account. **Google Play** ownership and **F-Droid** are still open. |
| **iOS push** | APNs **approved** (content-free payloads). Key and cert lifecycle still to handle. |
| **Mobilizon PUBLIC default** | Federated event titles visible on public URLs — app UI should not surprise parents ([EVENTS.md](EVENTS.md)). |
| **In-app chat scope** | Stage 1 chat is text only (no media, reactions, threads or calls). Room list and timeline come from a hand-written facade over `matrix-sdk`; move to `matrix-sdk-ui` (Timeline/RoomListService) as features grow. |
| **E2EE** | **On** from Stage 1. Risks: a lost recovery key means old messages are lost on a new phone; parents can't see content off the kid's device; server-side content filters (P3.6) can't work in encrypted rooms. Interactive SAS verification of other people is deferred. |
| **Box addressing** | QR `https://<main-domain>`; confirm `/.well-known/tinywebstack-family.json` fields match Matrix client discovery (`matrix_server` in [`app.py`](../family/dashboard/tinywebstack_dashboard/app.py)). |
| **OwnTracks Recorder API** | Exact read endpoints and auth for app proxy — confirm against Recorder version shipped on YunoHost. |
| **Enrollment security** | Rate limits, lockout, and audit log for enroll and revoke. |

---

## Related documents

- [FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md) — current parent web UI  
- [production-setup.md](production-setup.md) — production node layout  
- [PLAN.md](../PLAN.md) — stack direction and next milestone  
