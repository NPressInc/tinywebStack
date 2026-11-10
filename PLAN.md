# tinywebStack Plan

tinywebStack is a private, self-hosted app ecosystem for families that runs on hardware at home. It replaces the custom C platform in NPressInc/TinyWebC with existing, proven open-source software plus a thin family layer on top.

**Related docs:** [Design philosophy](docs/PHILOSOPHY.md) (principles adapted from TinyWebC) · [Family layer feature plan](docs/FAMILY_LAYER_PLAN.md) (v1 gaps and ordering) · [TinyWeb mobile app plan](docs/TINYWEB_APP_PLAN.md) · [Backups](docs/BACKUP.md) · [Test nodes lab](docs/test-nodes.md) · [Unboxing](docs/UNBOXING.md)

## Priority 1: unboxing

The number-one product priority is that buying a TinyWeb box feels like setting up a phone. A parent plugs it in and finishes in the TinyWeb app. The executable spec is [docs/UNBOXING.md](docs/UNBOXING.md).

The only steps a customer should see:

1. Plug in power and ethernet.
2. Open the TinyWeb app on the phone (App Store / Play Store), on the home Wi-Fi.
3. The phone finds the box. The card in the lid (and the sticker on the bottom) has a one-time setup QR. Scanning it opens the app, or the store first if the app is not installed, with the setup code filled in.
4. The parent names the family and chooses the first parent password.
5. A calm progress screen runs while the box becomes `<family>.tinyweb.win`, gets a real Let's Encrypt certificate, and finishes install.
6. The parent adds everyone else with the existing QR / one-link enrollment at `/family/join`.

The parent never sees a terminal, a router page, YunoHost, or a certificate warning. TinyWeb does not use ads. Production TLS is Let's Encrypt.

Workstreams, in order:

| | Workstream | Where it stands |
| --- | --- | --- |
| A | Pre-imaged box, plus a first-boot wizard the phone can talk to on the LAN | **This repo starts the software slice:** mDNS (and a LAN beacon), a local setup API, and the app wizard with progress. The setup code can be scanned or typed. A shippable disk image is specified in the unboxing doc and is not built here. |
| B | Control plane for family-slug reservation, DNS, and certificates | **Later.** Runs on William's service at tinyweb.win (vivo). It publishes `<family>.tinyweb.win` and `*.<family>.tinyweb.win` and obtains real Let's Encrypt certificates. Family traffic (chat, calendars, files, location) does not pass through that server. |
| C | Built-in tunnel so port forwarding is not required | **Later.** v1 default is a per-box tunnel to an edge. Cloudflare is the pragmatic default because tinyweb.win already uses it. vivo only issues tunnel credentials. The tunnel carries family traffic to the edge, not through vivo. |
| D | TinyWeb in the Apple App Store and Google Play Store | **Later.** Listing assets are not shipped. The setup QR's https link depends on this so a phone without the app can reach a store. |
| E | Push with TinyWeb-owned APNs/FCM credentials | **Later.** A family does not upload a `.p8` or a key file. |

Today an operator still follows [docs/production-setup.md](docs/production-setup.md): flash Debian/YunoHost, SSH, clone, edit `tinyweb.env`, run `scripts/install-tinyweb.sh` or `scripts/install-on-box.sh`, DNS and ports, copy secrets off the box, sideload the app, then QR enroll. That runbook stays for operators. Customers use the unboxing path.

v1 assumes the box is on ethernet and the phone is on the same home Wi-Fi. Wi-Fi-only first boot for the box itself is later.

Build on these pieces. Do not replace them: the one-box installer, bare family slug → `<family>.tinyweb.win`, `scripts/vm/tinyweb-subdomain-ddns.sh`, `TWS_TLS_SINGLE_SAN_CERT=1` (one SAN certificate), the parent dashboard, the health page, and QR join at `/family/join`.

The setup QR carries only that unit's pairing code (`https://tinyweb.win/setup#code=…` or `tinyweb://setup#code=…`, secret in the fragment). It is not the parent password and not a chat recovery key. The same code is how the box will prove itself to the control plane when claiming `<family>.tinyweb.win`. It stays valid if setup fails partway, and it is not enough to reclaim a box after the family is set up. The parent chooses the password in the app. The Matrix recovery key is generated on the first phone, shown once, and written on a blank card that ships in the box.

## Target hardware

TinyWeb is home-server software targeted at a **NAS or mini PC with 8 GB of RAM**. A Raspberry Pi is possible for light use, but an 8 GB mini PC or NAS is the main target; a full family box runs comfortably in 4 GB of RAM.

## Why the change

TinyWebC rebuilt things that already exist: a gossip protocol, a message store, and location storage. Mature projects already cover most of that. The only genuinely new part is the family layer: parent-managed identity and permissions that every app respects, and trusted links between households. That's where the effort goes now.

## Default family domains (`<family>.tinyweb.win`)

Production TinyWeb families use **`<family>.tinyweb.win`** as the default hostname scheme (for example `smith.tinyweb.win`, with service hosts such as `matrix.smith.tinyweb.win`, `mobilizon.smith.tinyweb.win`, `push.smith.tinyweb.win`, `owntracks.smith.tinyweb.win`, and `nextcloud.smith.tinyweb.win`). Custom domains (for example `family-b.family.test` or your own DNS) still work unchanged.

Bare family slugs are expanded automatically in the **TinyWeb app** (enrollment and Matrix ID entry) and in the **one-box installer** (`scripts/install-on-box.sh`, `scripts/install-tinyweb.sh --family`). Dynamic DNS and TLS for `tinyweb.win` families are handled by `scripts/vm/tinyweb-subdomain-ddns.sh`, which can update `A`/`AAAA` records via a TinyWeb webhook or Cloudflare and provision **one** Let's Encrypt certificate for `<family>.tinyweb.win` plus `*.<family>.tinyweb.win` so multiple service subdomains do not each consume a separate LE rate-limit slot on the shared `tinyweb.win` zone.

## The stack

- **Base OS:** [YunoHost](https://yunohost.org), a Debian-based self-hosting OS with an app catalog, user accounts and groups, single sign-on (one login for every app), per-app permissions, domains, and HTTPS.
- **Texting and calling:** Matrix on **Synapse** (homeserver). Families use the **TinyWeb app** for chat; voice/video calls land in a later app stage (Element Call on the box). Synapse uses YunoHost logins and can federate between homes.
- **Location:** OwnTracks Recorder or Traccar on the box; kids publish from the **TinyWeb app** (not the OwnTracks app).
- **Media:** Optional [Jellyfin](docs/JELLYFIN.md) from the official YunoHost package, off unless `TWS_JELLYFIN=1`, at `jellyfin.<family>.tinyweb.win`. Playback stays in Jellyfin’s phone and TV apps (the browser is only a fallback). People sign in again with their TinyWeb username and password. That is LDAP, not single sign-on. Children are not allowed to sign in until a parent grants it, and the packaged “all libraries” default for new accounts is turned off. Parents add folders and per-person library access in Jellyfin’s own dashboard. TinyWeb only shows the address. Quiet hours are not applied to Jellyfin. Immich and other catalog apps stay out of this integration.

## What we build (the family layer)

1. **Family accounts.** Parents create and manage accounts for their kids. Groups like `parents`, `kids`, and `family-<name>` map to YunoHost groups and app permissions.
2. **Linking trusted families.** Invites between households, plus rules for which outside users can contact which kids. On the Matrix side, this means federation allowlists and room and contact policies.
3. **Parental controls.** Contact allowlists, quiet hours, and parent visibility into a kid's activity. These are enforced where the apps allow it (Matrix server modules or admin API, per-app permissions).
4. **Location in the permission model.** Only a kid's own parents, or users the parents approve, can see that kid's location.
5. **Setup.** Scripts and docs that turn a fresh YunoHost install into a family node with a small number of steps.

## Backups

Parents manage backups from the dashboard at `/family/backup`. The page can start a backup, show whether it is running or why it failed, and keep a short history. Automatic backups stay **off** until a parent turns them on. Nothing is scheduled by installing the dashboard.

Backups call YunoHost’s `yunohost backup create` for family accounts (LDAP), app databases, and app files. TinyWeb’s own state — the permissions database, phone sign-in database, and `/etc/tinywebstack` — is added by a YunoHost backup hook that snapshots SQLite with the database backup API. Jellyfin and the shared media folder are not included, so a movie library cannot fill an 8 GB disk. A backup that stays on the box is not a spare copy. Restoring onto a replacement computer is a documented YunoHost restore, not a button on the page.

See [docs/BACKUP.md](docs/BACKUP.md).

## Out of scope for now

- Locking down Android phones (a custom ROM, device provisioning, pushing apps to phones). Until this exists, a kid with a normal phone can still install other apps, so "only approved apps" isn't enforced on the device.
- A custom gossip protocol or C node. TinyWebC stays as a reference.

## First milestones

1. Stand up YunoHost on a test machine and install Synapse (plus Element Web for operator debugging), OwnTracks Recorder or Traccar, and the family layer.
2. Document the users, groups, and permissions model for one family.
3. Prove that two YunoHost family nodes can federate over Matrix with an allowlist.
4. Write down the gaps that need custom code, and build the smallest one first.

## Next milestone: TinyWeb app

**Backends can be open-source apps; the frontend is unified.** Families use only the **TinyWeb app** (iOS/Android) and the **parent dashboard** (`/family/`) for everyday life — not Element X, the OwnTracks app, DAVx5, Nextcloud mobile apps, Mobilizon web, or Traccar web.

## Phone onboarding

A parent adds a person on the **family dashboard** or in the TinyWeb app. The box creates the account with the role the parent chose (a child only receives that role and the permissions the parent sets) and shows **one QR code**. The code encodes `https://<family>.tinyweb.win/family/join#code=…` (custom domains use the same `/family/join` path). The one-time code is in the URL **fragment**, so the family server does not receive it and does not write it to access logs. The link and QR do not contain the account password or any session token. Codes are **single-use**, last about **10 minutes** (`TWS_APP_CODE_TTL_S`, default 600), and failed attempts are rate-limited. Only a parent can create a code.

On the phone:

1. The camera opens the link. The page is public (no parent login).
2. If TinyWeb is installed, the page opens `tinyweb://enroll` and the app fills the family server (a bare name such as `smith` still means `smith.tinyweb.win`), enrolls with the code, and stores the chat, calendar, and location credentials the box already issues.
3. If TinyWeb is not installed, or the phone does not hand the link to the app, the page stays open with install instructions, the family server, and the code to type. The enroll screen always has those fields.
4. The app then shows **You're all set** with a checklist. Chat, calendar, events, and location are marked linked or not. Any step still left is explained in plain language: save the chat recovery key, allow location, or open Events and enter the family password once. A one-time code does not carry that password. Expired codes, already-used codes, a different family server, and an unreachable box each get their own message.

Enrollment does not add permissions beyond the role the parent set, and it does not weaken password login.

## Health

Parents can open **Is everything working?** at `/family/health` (linked from the family home, and from **Home health** in the TinyWeb app for parents only). It says in plain language whether chat, calendars, events, location, phone notifications, the website certificate, and disk space are OK, need a look, or have a problem, plus the last check time and a short hint. Optional apps such as Jellyfin and backups show **Not installed** when they are not on the box. Checks are read-only, time-limited, and cached. The page does not show secrets, run commands a parent types, or restart anything.

One **TinyWeb** mobile app (`app/`, Flutter) connects to every backend on the family box with one enrollment. **Chat is built into the app from Stage 1** (no Element X hand-off or in-app button), via **matrix-rust-sdk** through the small **`tinyweb_core` Rust bridge** (spike: PR #38). Chat is **end-to-end encrypted from Stage 1**: the box allows encrypted rooms and creates new rooms encrypted by default; the app sets up a **recovery key** and **key backup**; kid allowlists and quiet hours still apply (metadata on the server). Parent-key oversight of kid chats is **deferred**; parents read a kid's chats only on the kid's device for now. **Built-in background location** (Stage 1) posts OwnTracks-format JSON to the box’s existing Recorder HTTP endpoint; parents see traces in the app and on the dashboard map (kids do not need the OwnTracks app). **Release builds** run in CI on GitHub Actions (PR #41, `.github/workflows/app.yml`); spark (ARM64) cannot produce Android release artifacts; iOS needs macOS runners. Pin **matrix-rust-sdk** and upgrade deliberately. See [docs/TINYWEB_APP_PLAN.md](docs/TINYWEB_APP_PLAN.md).
