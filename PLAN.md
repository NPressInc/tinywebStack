# tinywebStack Plan

tinywebStack is a private, self-hosted app ecosystem for families that runs on hardware at home. It replaces the custom C platform in NPressInc/TinyWebC with existing, proven open-source software plus a thin family layer on top.

**Related docs:** [Design philosophy](docs/PHILOSOPHY.md) (principles adapted from TinyWebC) · [Family layer feature plan](docs/FAMILY_LAYER_PLAN.md) (v1 gaps and ordering) · [TinyWeb mobile app plan](docs/TINYWEB_APP_PLAN.md) · [Test nodes lab](docs/test-nodes.md)

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
- **Media and apps:** Jellyfin, Immich, Nextcloud, and others from the YunoHost catalog. Complex optional media apps like **Jellyfin** stay as their own separate native apps (phone/TV) rather than being built into the TinyWeb mega-app; family members sign into them automatically using their same TinyWeb username and password via YunoHost's shared LDAP directory.

## What we build (the family layer)

1. **Family accounts.** Parents create and manage accounts for their kids. Groups like `parents`, `kids`, and `family-<name>` map to YunoHost groups and app permissions.
2. **Linking trusted families.** Invites between households, plus rules for which outside users can contact which kids. On the Matrix side, this means federation allowlists and room and contact policies.
3. **Parental controls.** Contact allowlists, quiet hours, and parent visibility into a kid's activity. These are enforced where the apps allow it (Matrix server modules or admin API, per-app permissions).
4. **Location in the permission model.** Only a kid's own parents, or users the parents approve, can see that kid's location.
5. **Setup.** Scripts and docs that turn a fresh YunoHost install into a family node with a small number of steps.

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

One **TinyWeb** mobile app (`app/`, Flutter) connects to every backend on the family box with one enrollment. **Chat is built into the app from Stage 1** (no Element X hand-off or in-app button), via **matrix-rust-sdk** through the small **`tinyweb_core` Rust bridge** (spike: PR #38). Chat is **end-to-end encrypted from Stage 1**: the box allows encrypted rooms and creates new rooms encrypted by default; the app sets up a **recovery key** and **key backup**; kid allowlists and quiet hours still apply (metadata on the server). Parent-key oversight of kid chats is **deferred**; parents read a kid's chats only on the kid's device for now. **Built-in background location** (Stage 1) posts OwnTracks-format JSON to the box’s existing Recorder HTTP endpoint; parents see traces in the app and on the dashboard map (kids do not need the OwnTracks app). **Release builds** run in CI on GitHub Actions (PR #41, `.github/workflows/app.yml`); spark (ARM64) cannot produce Android release artifacts; iOS needs macOS runners. Pin **matrix-rust-sdk** and upgrade deliberately. See [docs/TINYWEB_APP_PLAN.md](docs/TINYWEB_APP_PLAN.md).
