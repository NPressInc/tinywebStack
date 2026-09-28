# tinywebStack Plan

tinywebStack is a private, self-hosted app ecosystem for families that runs on hardware at home. It replaces the custom C platform in NPressInc/TinyWebC with existing, proven open-source software plus a thin family layer on top.

## Why the change

TinyWebC rebuilt things that already exist: a gossip protocol, a message store, and location storage. Mature projects already cover most of that. The only genuinely new part is the family layer: parent-managed identity and permissions that every app respects, and trusted links between households. That's where the effort goes now.

## The stack

- **Base OS:** [YunoHost](https://yunohost.org), a Debian-based self-hosting OS with an app catalog, user accounts and groups, single sign-on (one login for every app), per-app permissions, domains, and HTTPS.
- **Texting and calling:** Matrix, using the Synapse server with the Element client. It provides encrypted text and voice/video calls, uses YunoHost logins, and can federate between homes.
- **Location:** OwnTracks or Traccar, self-hosted.
- **Media and apps:** Jellyfin, Immich, Nextcloud, and others from the YunoHost catalog.

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

1. Stand up YunoHost on a test machine and install Synapse, Element, and one location app.
2. Document the users, groups, and permissions model for one family.
3. Prove that two YunoHost family nodes can federate over Matrix with an allowlist.
4. Write down the gaps that need custom code, and build the smallest one first.
