# Family layer feature plan

This document breaks down the **family layer** described in [PLAN.md](../PLAN.md) (sections 1–5) into implementable features. It maps each feature to what **YunoHost**, **Synapse**, **Element**, and **OwnTracks** (with **Traccar** fallback) already provide, what **custom code** is still required, and a suggested **order** and **v1 vs later** priority.

**Current lab state** (see [test-nodes.md](test-nodes.md)):

- Two YunoHost nodes (`family-a`, `family-b`) with Synapse, Element, and OwnTracks (default; `LOCATION_APP=traccar` for fallback).
- Matrix federation works **pairwise** with `federation_domain_whitelist`; `matrix.org` is rejected in e2e checks.
- Test users (`alice`, `bob`) are created via `yunohost user create`; apps install with broad permissions (`all_users` / `visitors`).
- **Not built yet:** family groups, kid provisioning, contact allowlists, location permission automation, or a parent-facing setup wizard.

**Explicitly out of scope (v1):** Android ROM lockdown; centralized cross-family server; production TLS (lab uses private CA).

---

## Reference: platform capabilities (researched)

### YunoHost

- **Users:** `yunohost user create`, LDAP-backed accounts, SSO portal ([Users and portal](https://doc.yunohost.org/en/admin/users)).
- **Groups:** Custom groups (letters/spaces in names); default groups `all_users`, `visitors`, `admins` ([Groups and permissions](https://doc.yunohost.org/en/admin/users/groups_and_permissions)).
- **Permissions:** Per-app permissions (e.g. `synapse.main`, `traccar.main`); grant to groups or individual users via `yunohost user permission update`.
- **SSO:** Apps integrated with SSOwat/LDAP; permission filter can require `permission=cn=__APP__.main,...` ([SSO/LDAP integration](https://doc.yunohost.org/en/dev/packaging/advanced/sso_ldap_integration)).

### Synapse (modules)

Configured via `modules:` in homeserver config. Two relevant extension points:

1. **Spam checker callbacks** ([docs](https://matrix-org.github.io/synapse/latest/modules/spam_checker_callbacks.html)) — include:
   - `user_may_invite`, `user_may_join_room`, `user_may_create_room`
   - `check_event_for_spam` (reject messages)
   - `user_may_send_3pid_invite` (email/phone invites)
   - `check_registration_for_spam`, `check_login_for_spam`
   - Note: **server admins are exempt** from several checks (same as upstream spam checker behavior).

2. **Third-party rules callbacks** ([docs](https://matrix-org.github.io/synapse/latest/modules/third_party_rules_callbacks.html)) — include `on_create_room`, `check_event_allowed` (experimental; federation caveats documented upstream). Upstream recommends preferring spam checker `check_event_for_spam` over `check_event_allowed` for denials.

**Existing helper module:** [synapse-user-restrictions](https://github.com/matrix-org/synapse-user-restrictions) — regex rules for `invite` and `create_room` only (not DM content or federation by itself).

**Federation (config, not a module):** `federation_domain_whitelist`, `ip_range_whitelist` — already used in [scripts/vm/synapse-federation-allowlist.sh](../scripts/vm/synapse-federation-allowlist.sh).

**Admin API:** Standard Synapse admin APIs for users, rooms, and moderation (usable from family-layer scripts on the node).

### Traccar

- **Roles:** Admin, Manager, User; **Readonly user** and **Device readonly user** ([User management](https://www.traccar.org/user-management)).
- **Permissions model:** Objects (devices, geofences, etc.) linked to users via **Connections**; shared objects grant full access unless duplicated or device-readonly is set ([Permissions and groups](https://www.traccar.org/permissions-groups)).
- **Groups:** Device groups (nested); linking geofences/notifications to groups affects devices, **not** user ACLs until also linked to users.
- **API:** `POST /api/permissions` with `{ "userId", "deviceId" }` (and similar) to link users to devices ([API reference](https://www.traccar.org/api-reference), community examples on [traccar.org forums](https://www.traccar.org/forums/topic/apipermissons)).

### Element

- Web/mobile client; policy enforcement is on **Synapse** (and YunoHost login), not Element itself.

---

## Section 1 — Family accounts

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| F1.1 | **Canonical group model** | Parents manage who is in the household; kids get only kid-appropriate apps. | YunoHost groups + permission matrix | Convention + automation for `parents`, `kids`, optional `family-<slug>` | Shell script or small Python CLI: create groups, document naming; idempotent `yunohost user group create` | YunoHost postinstall | 1 | **Must** |
| F1.2 | **Create kid account** | Parent adds a child without giving them admin rights. | `yunohost user create`; Synapse user via SSO | Wizard/CLI that sets password, group membership, and default permissions in one step | Extend `create-matrix-test-users.sh` pattern → `family-user-create.sh` with `--role kid\|parent` | F1.1 | 2 | **Must** |
| F1.3 | **App permissions by role** | Kid sees Element + location; not Traccar admin or YunoHost admin. | `yunohost user permission update` per app | Map role → permission set (remove `all_users` where too broad; grant `kids` / `parents`) | Declarative YAML consumed by apply script | F1.1, apps installed | 3 | **Must** |
| F1.4 | **Matrix identity alignment** | Kid logs into Element as `@kid:family.domain`. | Synapse `server_name` = main domain ([yunohost-family-apps.sh](../scripts/vm/yunohost-family-apps.sh)); SSO | Ensure LDAP/SSO user matches localpart; document password reset flow | YunoHost + Synapse app docs; optional admin API check script | F1.2 | 3 | **Must** |
| F1.5 | **Parent admin surface (family dashboard)** | One place to manage kid allowlists and quiet hours. | YunoHost SSO + LDAP groups | Central **family dashboard** web app (parents group only) | [FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md), `install-family-dashboard.sh` | F1.2–F1.3 | 6 | **Must** |
| F1.6 | **Kid credential recovery** | Parent resets forgotten kid password. | `yunohost user update` | Audit log + parent-only command wrapper | Thin CLI calling YunoHost API | F1.2 | 7 | Later |

---

## Section 2 — Linking trusted families

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| L2.1 | **Federation allowlist pair** | Two households chat across Matrix without opening to the world. | `federation_domain_whitelist` snippet | Multi-node orchestration + verification | [configure-federation-pair.sh](../scripts/spark/configure-federation-pair.sh), [verify-federation-e2e.sh](../scripts/spark/verify-federation-e2e.sh) | Milestone 3 | Done (lab) | **Must** |
| L2.2 | **Trusted domain registry (local)** | Parent records “Smith family server is `smith.example.com`.” | Config file on node | Structured store + CLI to add/remove trusted domains | JSON/YAML in `/etc/tinywebstack/` + merge into Synapse snippet | L2.1 | 4 | **Must** |
| L2.3 | **Cross-household invite policy** | Kid may DM `@friend:trusted.domain` only if both parents agreed. | Spam checker `user_may_invite` / `check_event_for_spam` | Custom Synapse module reading per-kid allowlist (localpart + domain rules) | Python module: config file maintained by family CLI | F1.2, L2.2 | 5 | **Must** |
| L2.4 | **Household invite flow** | Parents link two homes without manual fingerprint swapping. | Federation allowlist scripts | Dashboard one-time invite code/link; redeem + verify peer (HTTPS + Synapse signing key) | PR2: invite create/redeem API; reuse [synapse-federation-allowlist.sh](../scripts/vm/synapse-federation-allowlist.sh) | L2.2 | 5 | **Must** (PR2) |
| L2.5 | **Central trust broker** | Easier discovery of many families. | — | Whole service | Not planned | — | — | **Deferred** |
| L2.6 | **In-person proximity invite** | Strong assurance invitee is physically present. | — | Client + server validation | TinyWebC-style NFC/BLE flow ([in_person_invitation.md](https://github.com/NPressInc/TinyWebC/blob/main/ideas/in_person_invitation.md)) | Mobile clients | 12+ | Later |

---

## Section 3 — Parental controls

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| P3.1 | **Kid cannot create public rooms** | Reduces exposure to strangers. | `user_may_create_room`, `user_may_publish_room`; synapse-user-restrictions | Apply restrictions to kid MXIDs | Install synapse-user-restrictions **or** tiny custom module with same callbacks | F1.4 | 4 | **Must** |
| P3.2 | **Contact allowlist (Matrix)** | Kid only invites/DMs approved Matrix IDs. | `user_may_invite`, `check_event_for_spam` (for m.room.message) | Module + per-user JSON allowlist edited by parents | Single `tinywebstack_family` Synapse module | L2.3, F1.2 | 5 | **Must** |
| P3.3 | **Block 3PID invites** | Kid cannot invite via email/phone to bypass allowlist. | `user_may_send_3pid_invite` | Deny for kid role in module | Same module as P3.2 | P3.2 | 5 | **Must** |
| P3.4 | **Quiet hours / bedtime** | No Matrix traffic late night (server-enforced). | No built-in schedule | Time-based checks in spam checker (timezone-aware, midnight wrap) | `quiet_hours` per kid in `/etc/tinywebstack/family-policy.json` | P3.2 | 5 | **Must** |
| P3.5 | **Parent visibility (activity summary)** | Parent sees who kid messaged (metadata). | Synapse admin API / room membership | Read-only report script; respect E2EE (content not visible) | Cron + admin token → daily summary | F1.2 | 9 | Later |
| P3.6 | **Keyword / content filter** | Block specific words in plaintext rooms. | `check_event_for_spam` | Module rules; v1 rooms are **not** E2EE by default | Optional; document limitation | P3.2 | 10 | Later |
| P3.8 | **E2EE off by default** | Parents can moderate plaintext family rooms. | Synapse room defaults | `encryption_enabled_by_default_for_room_type: off`; reject `m.room.encryption` | `tinywebstack_family` third-party rules + config flag | P3.2 | 5 | **Must** |
| P3.9 | **Parent key decrypt (deferred)** | Parent reads kid messages per permission (TinyWebC-style). | — | Crypto + client work | Record only; not in v1 | — | — | **Deferred** |
| P3.7 | **Screen time on device** | Limit app usage on phone. | — | OS-level | Out of scope per PLAN | — | — | **Out of scope** |

**Note:** Synapse server administrators bypass some spam-checker hooks; family **parent** accounts must not be Synapse server admins unless intentional.

---

## Section 4 — Location in the permission model

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| G4.1 | **Kid publishes location (OwnTracks)** | Parent sees kid on map. | OwnTracks Recorder + mobile app (HTTP/MQTT) | Per-user credentials; kid uses app only | Default `LOCATION_APP=owntracks`; [prep-owntracks-apt.sh](../scripts/vm/prep-owntracks-apt.sh) | F1.2 | 4 | **Must** |
| G4.2 | **Parent-only location web** | Parents see all kid traces; kids cannot browse map. | YunoHost app permissions | `family-groups.sh` grants `owntracks.main` to `parents` only | F1.3 | 5 | **Must** |
| G4.3 | **Trusted adult (other household)** | Godparent sees location if parents approve. | OwnTracks / Traccar ACL | Extra viewer accounts in family config | Extend dashboard later | G4.2, L2.2 | 7 | Later |
| G4.4 | **Traccar fallback** | Same lab without OwnTracks apt. | Traccar catalog app | `LOCATION_APP=traccar`; existing setup scripts | [yunohost-family-apps.sh](../scripts/vm/yunohost-family-apps.sh) | F1.3 | 4 | **Fallback** |
| G4.5 | **Hide location web from kid SSO** | Kid cannot open web map of friends. | YunoHost permission on location app | Kid gets mobile publisher only | `family-groups.sh` | F1.3 | 4 | **Must** |

---

## Section 5 — Setup

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| S5.1 | **Lab / test node path** | Developers prove federation. | [test-nodes.md](test-nodes.md), spark scripts | Maintain docs | Keep scripts idempotent | — | Done | **Must** |
| S5.2 | **Production install runbook** | Parent with hardware gets a family node. | YunoHost installer | Single markdown path: OS → YunoHost → apps → family CLI | `docs/production-setup.md` (future) + reuse vm scripts | F1.* | 6 | **Must** |
| S5.3 | **`family-init` orchestrator** | One command after postinstall. | Individual vm scripts | Wrapper: groups, module, dashboard, test users | [family-init.sh](../scripts/vm/family-init.sh) | F1.3, P3.1, G4.2 | 6 | **Must** |
| S5.4 | **Synapse family module packaging** | Repeatable install on YunoHost. | `conf.d` snippets pattern | Debian package or YunoHost hook dropping module + venv | `.deb` or `yunohost` custom service doc | P3.2 | 6 | **Must** |
| S5.5 | **Validate script** | CI catches broken shell. | [validate.sh](../scripts/validate.sh) | Extend checks for new scripts | Add shellcheck targets | S5.3 | 7 | **Must** |

---

## Suggested implementation sequence (v1)

```text
1. F1.1 → F1.2 → F1.3 → F1.4 → F1.5   (groups, users, permissions, dashboard)
2. L2.1 (done) → L2.2 → L2.4 (invite)   (federation pair + dashboard invite flow)
3. P3.1 → P3.2 → P3.3 → P3.4 → P3.8   (Synapse module, allowlists, quiet hours, E2EE off)
4. G4.1 → G4.5 → G4.2                 (OwnTracks default + parent-only web)
5. S5.3 → S5.4 → S5.2                 (orchestrator + packaging + runbook)
```

Parallel work: **P3.*** (Synapse) and **G4.*** (OwnTracks) can proceed independently after **F1.***.

---

## Smallest v1 “family module” architecture (proposal)

Components on each node:

- **Policy store:** `/etc/tinywebstack/family-policy.json` — kid MXIDs, allowlists, quiet hours, trusted domains, parent MXIDs (written by the dashboard).
- **Synapse:** `tinywebstack_family` module — spam checker + encryption rejection ([FAMILY_MODULE.md](FAMILY_MODULE.md)).
- **Dashboard:** FastAPI app at `/family/` — parents group via SSO ([FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md)).
- **VM scripts:** `family-groups.sh`, `install-family-module.sh`, `install-family-dashboard.sh`, `family-init.sh`.
- **Clients (v1):** **Element X** (and Element Android/iOS) for chat; **OwnTracks** app for location. Element Web may remain for admins; not the kid client.
- **No centralized cloud** in v1.

---

## Decisions (recorded 2026-09-28)

William Floyd confirmed:

1. **Kid Matrix clients:** Target **mobile apps** (Element X / Element Android/iOS), not Element Web as the kid client.
2. **Parent vs admin:** **Family dashboard** for parents; parent Matrix accounts are ordinary **non-admin** Synapse users so spam-checker rules apply. `twsowner` (YunoHost admin) stays separate.
3. **E2EE:** **Off in v1** — unencrypted family rooms by default; Synapse config + module rejects `m.room.encryption`. **Deferred:** parent-key decrypt scheme (TinyWebC-style).
4. **Cross-household contact:** **Per-kid allowlist** is enough; no reciprocal approval between households.
5. **Location:** **OwnTracks** (Recorder + app) is the default stack; **Traccar** is fallback only (`LOCATION_APP=traccar`). Kid location visible to **parents only** (web UI permissions).
6. **OwnTracks install:** Fix unattended install on Debian 12 arm64/amd64 ([prep-owntracks-apt.sh](../scripts/vm/prep-owntracks-apt.sh)) — current signing key + `signed-by`, with `.deb` fallback.
7. **Linking families:** **Invite flow** in dashboard (one-time code/link, mutual verification, federation allowlist update) replaces manual domain/fingerprint ceremony (PR2).
8. **Quiet hours:** **Server-enforced** in v1 (per kid, timezone-aware, including midnight wrap).

---

## Related documents

- [PLAN.md](../PLAN.md) — direction and milestones  
- [PHILOSOPHY.md](PHILOSOPHY.md) — design principles adapted from TinyWebC  
- [test-nodes.md](test-nodes.md) — lab topology and federation verification  
