# tinywebStack design philosophy

This document states the design philosophies behind **tinywebStack**, adapted from the predecessor project [NPressInc/TinyWebC](https://github.com/NPressInc/TinyWebC). Each principle cites its source in TinyWebC and notes how it applies to the new stack: **YunoHost + Matrix (Synapse/Element) + location (Traccar or OwnTracks) + a thin family layer**, instead of a custom C gossip node.

For implementation planning, see [FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md). For the overall direction, see [PLAN.md](../PLAN.md).

---

## Summary: carry-over, adaptation, and retirement

| Status | Meaning |
|--------|---------|
| **Carries over** | Same intent; tinywebStack pursues it with different machinery |
| **Adapted** | Same goal, but the mechanism or scope changes with YunoHost/Matrix |
| **Deferred / out of scope** | Still aligned with values, but not in current milestones |
| **Retired** | Was tied to the custom gossip/PBFT platform and is not a tinywebStack goal |

---

## Principles

### 1. Family-first, not open-web-by-default

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — opening paragraph (“private, family-focused communication network”) and the “Why TinyWeb?” section (kids need phones; full smartphones open the flood gates; parental controls on the open web are insufficient).

**TinyWebC wording (spirit):** Put the child in a small, parent-approved library—not the entire uncatalogued internet.

**tinywebStack:** **Carries over.** Families still need communication and safety without treating the public internet as the default environment. The family layer defines who is a parent, who is a kid, and which outsiders may contact whom. Matrix federation and YunoHost app permissions enforce that at the server; device-level lockdown remains out of scope until a custom ROM exists (see [PLAN.md](../PLAN.md)).

---

### 2. Self-hosted at home, private by default

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — “decentralized application that runs on nodes within the parent's households”; “Each network will be completely private, encrypted, and free from any intervention since the networks are hosted at home!”

**tinywebStack:** **Adapted.** “Node” means a **YunoHost family server** at home (or a lab VM standing in for one), not a custom gossip process. Privacy comes from owning the hardware, controlling domains and TLS, and **restricting Matrix federation** (for example `federation_domain_whitelist` as in [test-nodes.md](test-nodes.md)). Encryption is provided by Matrix (including E2EE for room content) and HTTPS everywhere YunoHost serves apps.

---

### 3. Build the family layer; reuse everything else

**Source:** [TinyWebC `PLAN.md`](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) — roadmap repeatedly defers “extensions,” dashboard, and mobile apps while prioritizing user management and permissions; [tinywebStack `PLAN.md`](../PLAN.md) states explicitly that gossip, message store, and location storage already exist elsewhere.

**tinywebStack:** **Carries over (sharpened).** Engineering effort goes into **parent-managed identity, linking trusted households, parental controls, and location visibility**—not another chat protocol or GPS database. Synapse, Element, Traccar, Jellyfin, Immich, and Nextcloud come from mature projects and the YunoHost catalog.

---

### 4. Trusted links between households, not global social graph

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — families “join each other's network with the right permissions”; kids interact with “trusted members of the community”; parents coordinate events and playdates.

**tinywebStack:** **Adapted.** Cross-household trust is modeled as **explicit federation allowlists** and per-kid contact rules (see [FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md)), not gossip peer lists or a custom proximity protocol. A centralized “cross-family” server is **deferred**; pairwise federation between known homes is the current model ([test-nodes.md](test-nodes.md)).

---

### 5. Parent-managed accounts and permissions

**Source:** [TinyWebC `PLAN.md`](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) — Phase 1 user registration API, role assignment, permissions integration; [TinyWebC `docs/KEY_DISTRIBUTION_ARCHITECTURE.md`](https://github.com/NPressInc/TinyWebC/blob/main/docs/KEY_DISTRIBUTION_ARCHITECTURE.md) — “Parent-controlled provisioning.”

**tinywebStack:** **Adapted.** Parents create **YunoHost users** for kids and place them in groups (`parents`, `kids`, `family-<name>`). App access uses YunoHost **groups and permissions** (SSO/LDAP). Matrix identities map to those users via SSO. Cryptographic child key provisioning via QR (TinyWebC) becomes **account creation + SSO + optional Matrix device management**, not node-stored private keys.

---

### 5b. One dashboard for non-technical families

**tinywebStack:** **Carries over (product core).** The **TinyWeb parent dashboard** (`/family/` on the main domain) is the **only** interface a non-technical family should need for everyday life: add or remove parents and children, reset passwords, see whether chat is working, set who kids may message, link another home, and set up location on a child’s phone. **YunoHost admin**, **Synapse admin**, and **OwnTracks/Traccar admin UIs** remain available for installers and power users, but they are **optional**, not part of the parent story. If a workflow still requires opening those panels, treat that as a family-layer gap to close.

---

### 6. Encryption and least privilege on the server

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — “encrypted message relay”; [KEY_DISTRIBUTION_ARCHITECTURE.md](https://github.com/NPressInc/TinyWebC/blob/main/docs/KEY_DISTRIBUTION_ARCHITECTURE.md) — “End-to-end encryption — Messages encrypted by clients, nodes cannot decrypt”; “Nodes only store public keys.”

**tinywebStack:** **Adapted.** Matrix provides **E2EE** for supported room types; the homeserver still sees metadata (who talks to whom, when). Location data in Traccar is protected by **Traccar user/device permission links**, not TinyWebC’s custom encrypted location API. The spirit—**servers verify and route, they do not become a readable copy of family life**—still guides what we log, what parents can see, and what we refuse to build (for example, a centralized family spy server).

---

### 7. Curated ecosystem: “a few approved books,” not the whole library

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — library metaphor; business plan mentions Jellyfin, Immich, and an extensions catalog.

**tinywebStack:** **Adapted.** “Approved books” means **which YunoHost apps each group may open** (Element, Traccar, Jellyfin, etc.) and **which Matrix rooms and federated domains exist**. Extensions are **YunoHost apps** (and future family-layer automation), not Docker sidecars wired to a custom gossip bridge—unless we explicitly add bridge apps later.

---

### 8. Open source backend; optional paid hosting

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — “Business Plan” (open source backend and Android apps; paid hosting only if desired).

**tinywebStack:** **Carries over.** This repository stays open source. Revenue, if any, remains **hosting-as-a-service**, not licensing the family layer or the underlying apps (Synapse, Traccar, YunoHost are already open source under their own licenses).

---

### 9. Invitations should reflect real-world trust

**Source:** [TinyWebC `ideas/in_person_invitation.md`](https://github.com/NPressInc/TinyWebC/blob/main/ideas/in_person_invitation.md) — “Only allow network joins through physical presence verification”; “Family-focused, parent-controlled”; “Maintains TinyWeb's locked-down, isolated design philosophy.”

**tinywebStack:** **Adapted (partially deferred).** v1 uses **parent-approved federation** (allowlisted domains, admin-mediated invites) rather than NFC/BLE proximity proofs. In-person or high-assurance invite flows remain a **later** enhancement once basic linking works ([FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md)).

---

### 10. Parental controls enforced where the stack allows

**Source:** [TinyWebC `PLAN.md`](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) — Phase 2 parental controls (screen time, content filters, quiet time); permissions enforcement called “security critical.”

**tinywebStack:** **Adapted.** Enforcement uses **Synapse modules** (spam-checker callbacks such as `user_may_invite`, `check_event_for_spam`; optional [synapse-user-restrictions](https://github.com/matrix-org/synapse-user-restrictions)), **YunoHost permissions**, and **Traccar readonly roles**—not custom protobuf handlers. Screen time on the **device OS** is out of scope until Android lockdown exists.

---

### 11. Location visible only to authorized caregivers

**Source:** [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) — Location API “only accessible to authorized users (self, parents, or admins)”; [PLAN.md](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) — GPS tracking for parental monitoring.

**tinywebStack:** **Adapted.** Traccar (or OwnTracks) holds positions; **device–user permission links** and group structure determine who sees which kid. The family layer should assign devices and links when a parent creates a kid account ([FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md)).

---

## Retired or no longer applicable (TinyWebC-specific)

These were real goals in TinyWebC but are **not** tinywebStack principles—they were implementation choices superseded by the new stack:

| Topic | Source | Why it does not carry over |
|-------|--------|----------------------------|
| Custom gossip / UDP transport | [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md), [SETUP.md](https://github.com/NPressInc/TinyWebC/blob/main/SETUP.md) | Replaced by Matrix federation |
| Protobuf-over-gossip message taxonomy (40+ types) | [TinyWebC `PLAN.md`](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) | Matrix events + app-specific APIs |
| SQLite as the primary message store on the node | [TinyWebC `README.md`](https://github.com/NPressInc/TinyWebC/blob/main/README.md) | Synapse’s database |
| Node-stored user private keys | [KEY_DISTRIBUTION_ARCHITECTURE.md](https://github.com/NPressInc/TinyWebC/blob/main/docs/KEY_DISTRIBUTION_ARCHITECTURE.md) | Matrix + YunoHost auth model |
| Optional PBFT blockchain feature | [TinyWebC `SETUP.md`](https://github.com/NPressInc/TinyWebC/blob/main/SETUP.md) | Not part of tinywebStack |
| Gossip-based app distribution / OTA to phones | [TinyWebC `PLAN.md`](https://github.com/NPressInc/TinyWebC/blob/main/PLAN.md) Phase 4 | Out of scope until device provisioning exists |

---

## How to use this document

When adding a feature, ask:

1. Does it strengthen **family-first, self-hosted, least-privilege** (principles 1–2, 6)?
2. Is it **family-layer** work, or are we rebuilding Synapse/YunoHost/Traccar (principle 3)?
3. Does it respect **trusted-household** boundaries (principles 4, 9)?
4. Are we honest about **what the server can still see** (principle 6)?

If the answer conflicts with [PLAN.md](../PLAN.md), update the plan deliberately—do not drift silently.
