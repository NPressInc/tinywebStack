# Family layer feature plan

This document breaks down the **family layer** described in [PLAN.md](../PLAN.md) (sections 1–5) into implementable features. It maps each feature to what **YunoHost**, **Synapse**, **Element**, and **Traccar** already provide, what **custom code** is still required, and a suggested **order** and **v1 vs later** priority.

**Current lab state** (see [test-nodes.md](test-nodes.md)):

- Two YunoHost nodes (`family-a`, `family-b`) with Synapse, Element, and Traccar (default).
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
| F1.5 | **Parent admin surface** | One place to add/remove family members. | YunoHost web admin | Family-layer UI or guided CLI; avoid building full dashboard in v1 | Script bundle + markdown runbook; optional lightweight web UI later | F1.2–F1.3 | 6 | Later |
| F1.6 | **Kid credential recovery** | Parent resets forgotten kid password. | `yunohost user update` | Audit log + parent-only command wrapper | Thin CLI calling YunoHost API | F1.2 | 7 | Later |

---

## Section 2 — Linking trusted families

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| L2.1 | **Federation allowlist pair** | Two households chat across Matrix without opening to the world. | `federation_domain_whitelist` snippet | Multi-node orchestration + verification | [configure-federation-pair.sh](../scripts/spark/configure-federation-pair.sh), [verify-federation-e2e.sh](../scripts/spark/verify-federation-e2e.sh) | Milestone 3 | Done (lab) | **Must** |
| L2.2 | **Trusted domain registry (local)** | Parent records “Smith family server is `smith.example.com`.” | Config file on node | Structured store + CLI to add/remove trusted domains | JSON/YAML in `/etc/tinywebstack/` + merge into Synapse snippet | L2.1 | 4 | **Must** |
| L2.3 | **Cross-household invite policy** | Kid may DM `@friend:trusted.domain` only if both parents agreed. | Spam checker `user_may_invite` / `check_event_for_spam` | Custom Synapse module reading per-kid allowlist (localpart + domain rules) | Python module: config file maintained by family CLI | F1.2, L2.2 | 5 | **Must** |
| L2.4 | **Pairwise link ceremony** | Parents establish trust out-of-band. | Manual allowlist edit | Two-parent workflow: exchange domain, confirm fingerprint (TLS or signing key) | Documented runbook; optional signed “trust token” file exchanged email/USB | L2.2 | 5 | **Must** |
| L2.5 | **Central trust broker** | Easier discovery of many families. | — | Whole service | Not planned | — | — | **Deferred** |
| L2.6 | **In-person proximity invite** | Strong assurance invitee is physically present. | — | Client + server validation | TinyWebC-style NFC/BLE flow ([in_person_invitation.md](https://github.com/NPressInc/TinyWebC/blob/main/ideas/in_person_invitation.md)) | Mobile clients | 12+ | Later |

---

## Section 3 — Parental controls

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| P3.1 | **Kid cannot create public rooms** | Reduces exposure to strangers. | `user_may_create_room`, `user_may_publish_room`; synapse-user-restrictions | Apply restrictions to kid MXIDs | Install synapse-user-restrictions **or** tiny custom module with same callbacks | F1.4 | 4 | **Must** |
| P3.2 | **Contact allowlist (Matrix)** | Kid only invites/DMs approved Matrix IDs. | `user_may_invite`, `check_event_for_spam` (for m.room.message) | Module + per-user JSON allowlist edited by parents | Single `tinywebstack_family` Synapse module | L2.3, F1.2 | 5 | **Must** |
| P3.3 | **Block 3PID invites** | Kid cannot invite via email/phone to bypass allowlist. | `user_may_send_3pid_invite` | Deny for kid role in module | Same module as P3.2 | P3.2 | 5 | **Must** |
| P3.4 | **Quiet hours / bedtime** | No Matrix traffic late night (policy choice). | No built-in schedule | Time-based checks in `check_event_for_spam` / login callback | Config `quiet_hours` per user in family store | P3.2 | 8 | Later |
| P3.5 | **Parent visibility (activity summary)** | Parent sees who kid messaged (metadata). | Synapse admin API / room membership | Read-only report script; respect E2EE (content not visible) | Cron + admin token → daily summary | F1.2 | 9 | Later |
| P3.6 | **Keyword / content filter** | Block specific words in plaintext rooms. | `check_event_for_spam` | Module rules; ineffective for E2EE rooms | Optional; document limitation | P3.2 | 10 | Later |
| P3.7 | **Screen time on device** | Limit app usage on phone. | — | OS-level | Out of scope per PLAN | — | — | **Out of scope** |

**Note:** Synapse server administrators bypass some spam-checker hooks; family **parent** accounts must not be Synapse server admins unless intentional.

---

## Section 4 — Location in the permission model

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| G4.1 | **Kid device in Traccar** | Parent sees kid on map. | Traccar devices + Traccar app on phone | Register device; unique id per kid | Script: create device, store id in family config | F1.2, Traccar installed | 4 | **Must** |
| G4.2 | **Parent linked to kid device** | Both parents see kid; kid sees self only. | Traccar user permissions API | Auto `POST /api/permissions` parent↔device; kid user readonly on own device | Python/shell using Traccar admin session | G4.1, F1.3 | 5 | **Must** |
| G4.3 | **Trusted adult (other household)** | Godparent sees location if parents approve. | Traccar user + permission link | Family config lists extra Traccar user IDs; apply permissions | Extend family CLI | G4.2, L2.2 | 7 | Later |
| G4.4 | **OwnTracks path** | Same policy on alternate location app. | OwnTracks YunoHost app ([test-nodes.md](test-nodes.md)) | OwnTracks ACL model differs from Traccar | Separate adapter script; pick one app as default per node | LOCATION_APP | 8 | Later |
| G4.5 | **Hide location app from kid SSO** | Kid cannot open web map of friends. | YunoHost permission on `traccar.main` | Kid gets tracker client only; no Traccar web tile | Permission map in F1.3 | F1.3 | 4 | **Must** |

---

## Section 5 — Setup

| ID | Feature | Parent / kid value | Stack already provides | Gap (custom) | Smallest approach | Depends on | Order | v1 |
|----|---------|-------------------|------------------------|--------------|-------------------|------------|-------|-----|
| S5.1 | **Lab / test node path** | Developers prove federation. | [test-nodes.md](test-nodes.md), spark scripts | Maintain docs | Keep scripts idempotent | — | Done | **Must** |
| S5.2 | **Production install runbook** | Parent with hardware gets a family node. | YunoHost installer | Single markdown path: OS → YunoHost → apps → family CLI | `docs/production-setup.md` (future) + reuse vm scripts | F1.* | 6 | **Must** |
| S5.3 | **`family-init` orchestrator** | One command after postinstall. | Individual vm scripts | Wrapper: groups, apps permissions, module deploy, Traccar baseline | `scripts/vm/family-init.sh` calling sub-steps | F1.3, P3.1, G4.2 | 6 | **Must** |
| S5.4 | **Synapse family module packaging** | Repeatable install on YunoHost. | `conf.d` snippets pattern | Debian package or YunoHost hook dropping module + venv | `.deb` or `yunohost` custom service doc | P3.2 | 6 | **Must** |
| S5.5 | **Validate script** | CI catches broken shell. | [validate.sh](../scripts/validate.sh) | Extend checks for new scripts | Add shellcheck targets | S5.3 | 7 | **Must** |

---

## Suggested implementation sequence (v1)

```text
1. F1.1 → F1.2 → F1.3 → F1.4     (accounts + permissions + Matrix IDs)
2. L2.2 → L2.4                     (trust registry + runbook; builds on existing L2.1)
3. P3.1 → P3.2 → P3.3              (Synapse module + allowlists)
4. G4.1 → G4.5 → G4.2              (Traccar devices + SSO + permission links)
5. S5.3 → S5.4 → S5.2              (orchestrator + packaging + runbook)
```

Parallel work: **P3.*** (Synapse) and **G4.*** (Traccar) can proceed independently after **F1.***.

---

## Smallest v1 “family module” architecture (proposal)

One Python package on the node:

- **Config:** `/etc/tinywebstack/family.yaml` — groups, users, roles, trusted domains, Matrix allowlists, Traccar device ids.
- **Synapse:** Module registering spam checker callbacks (invite, message, 3pid, room create).
- **CLI:** `tinywebstack-family apply` — reads YAML, calls YunoHost CLI, Traccar API, renders Synapse allowlist snippet if needed.
- **No centralized cloud** in v1.

---

## Open questions for William

1. **Default location app:** Standardize on **Traccar** for v1, or require **OwnTracks** for parity with a future mobile client?
2. **Kid Matrix clients:** Element Web only in v1, or target Element X / another client for allowlist testing?
3. **Parent vs server admin:** Should the YunoHost admin (`twsowner`) also be Synapse admin, or should parents use a non-admin Synapse account for day-to-day use (so spam-checker rules apply)?
4. **E2EE default:** Should family rooms be **encrypted by default**, accepting that P3.6 content filters and some moderation hooks are limited?
5. **Cross-household kid contact:** Is allowlist **per kid** sufficient, or do we need **reciprocal approval** (both homes confirm) before any DM is allowed?
6. **Traccar accounts:** One Traccar user per human (SSO-linked), or shared parent login plus separate device tokens for kids?
7. **Trust ceremony:** Is manual domain + TLS fingerprint enough for v1, or do you want an signed exchange format in-repo?
8. **Quiet hours:** Server-enforced (P3.4) for v1, or document as parental process until mobile clients exist?

---

## Related documents

- [PLAN.md](../PLAN.md) — direction and milestones  
- [PHILOSOPHY.md](PHILOSOPHY.md) — design principles adapted from TinyWebC  
- [test-nodes.md](test-nodes.md) — lab topology and federation verification  
