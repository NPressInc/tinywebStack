# YunoHost test nodes on `spark` (milestones 1 and 3)

Headless KVM/libvirt VMs on **spark**, YunoHost + Synapse/Element/location app, Matrix federation with an allowlist.

## Paths on spark

| Purpose | Path |
|--------|------|
| Git checkout | e.g. `~/Documents/codingProj/tinywebStack` |
| VM disks & seeds | `/var/lib/libvirt/images/tinywebstack` |
| Cloud images | `/var/lib/libvirt/images/tinywebstack/images` |
| Secrets & lab CA | `~/.tinywebstack-secrets/` (`passwords.env`, `lab-ca/`, `known_hosts`) |

Do not use the same directory for the git repo and VM data.

## App layout (per node)

| Service | Hostname | Notes |
|---------|----------|--------|
| YunoHost main | `family-a.family.test` | postinstall domain |
| Synapse | `matrix.family-a.family.test` | `server_name=family-a.family.test` → `@user:family-a.family.test` |
| Element | `element.family-a.family.test` | Web client |
| Location (default) | `owntracks.family-a.family.test` | OwnTracks Recorder + app; set `LOCATION_APP=traccar` for catalog fallback |
| Nextcloud CalDAV | `nextcloud.family-a.family.test` | Calendar app; web tile hidden — phones use CalDAV ([CALENDAR.md](CALENDAR.md)) |
| Events (Mobilizon) | `mobilizon.family-a.family.test` | SSO/LDAP; arm64 catalog package; see [EVENTS.md](EVENTS.md) |
| Family dashboard | `https://family-a.family.test/family/` | Parents group only (after `family-init.sh`) |

`apply-private-dns.sh` adds all of these names to spark’s `/etc/hosts`. Push peer entries to each VM with:

```bash
./scripts/spark/sync-all-vm-peer-hosts.sh
```

## SSH after YunoHost

- Cloud-init creates **`twsadmin`** (initial access) and installs your SSH key on **`root`** (YunoHost allows root from local/LAN networks).
- **`remote-run.sh` defaults to `root@IP`** (`REMOTE_SSH_USER`) after postinstall.
- YunoHost admin LDAP user is **`twsowner`** by default (`YUNOHOST_ADMIN_USER`), separate from `twsadmin`.
- Host keys: first `remote-run` records keys via `ssh-keyscan` into `~/.tinywebstack-secrets/known_hosts`.

---

## Prerequisites on `spark`

```bash
sudo usermod -aG libvirt,kvm "$USER"
# Log out and back in, or until then:
sg libvirt -c './scripts/spark/deploy-test-nodes.sh'
```

Packages:

```bash
sudo apt update
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" = amd64 ]; then
  sudo apt install -y qemu-kvm libvirt-daemon-system virtinst virt-viewer \
    genisoimage cloud-image-utils curl rsync qemu-utils
else
  sudo apt install -y qemu-system-arm qemu-efi-aarch64 qemu-utils \
    libvirt-daemon-system virtinst virt-viewer \
    genisoimage cloud-image-utils curl rsync
fi
```

Repo setup:

```bash
cd ~/Documents/codingProj/tinywebStack
cp config/nodes.conf.example config/nodes.conf
cp config/defaults.env.example config/local.env   # optional
mkdir -p ~/.tinywebstack-secrets && chmod 700 ~/.tinywebstack-secrets
export LIBVIRT_DEFAULT_URI=qemu:///system   # or set in local.env
```

---

## End-to-end (automated pieces)

```bash
chmod +x scripts/**/*.sh scripts/*.sh

./scripts/spark/stage-lab-certs.sh
./scripts/spark/deploy-test-nodes.sh    # pool, secrets, VMs (autostart on)

virsh domifaddr tws-family-a
virsh domifaddr tws-family-b
sudo ./scripts/spark/apply-private-dns.sh   # only sudo step
```

Per node (`NODE_NAME=family-a`, `DOMAIN=family-a.family.test`, `IP=…`):

```bash
./scripts/vm/remote-run.sh "$IP" yunohost-bootstrap.sh "$DOMAIN" "$NODE_NAME"
./scripts/vm/remote-run.sh "$IP" yunohost-family-apps.sh "$DOMAIN" "$NODE_NAME"
./scripts/vm/remote-run.sh "$IP" create-matrix-test-users.sh "$DOMAIN" "$NODE_NAME"
./scripts/vm/remote-run.sh "$IP" family-init.sh "$DOMAIN" "$NODE_NAME"
# family-init installs Mobilizon + family calendars; or explicitly:
# ./scripts/vm/remote-run.sh "$IP" install-mobilizon.sh "$DOMAIN" "$NODE_NAME"
./scripts/spark/sync-vm-peer-hosts.sh "$NODE_NAME" "$IP"
```

### Lab-only shared password (`LAB_PASSWORD`)

For disposable test VMs you can set **`LAB_PASSWORD`** in `config/local.env` (or export it before deploy). When set, `ensure-node-secrets.sh` uses that value for every generated test secret instead of random strings:

- YunoHost admin, alice, bob, parent, kid, Traccar admin (per node)

**Never set `LAB_PASSWORD` on real deployments.** Existing entries in `passwords.env` are not overwritten; delete the relevant keys or remove the file if you change `LAB_PASSWORD` mid-lab.

YunoHost’s password policy requires **at least 8 characters** for admin and user accounts. Shorter `LAB_PASSWORD` values will cause user creation or bootstrap to fail.

Default (unset): each secret is a unique random value.

---

Passwords are generated on spark by `ensure-node-secrets.sh` into `~/.tinywebstack-secrets/passwords.env`:

- `YUNOHOST_ADMIN_PASSWORD_FAMILY_A`
- `ALICE_PASSWORD_FAMILY_A` / `BOB_PASSWORD_FAMILY_B`
- `TRACCAR_ADMIN_LOGIN_FAMILY_A` (email login, e.g. `admin@family-a.family.test`)
- `TRACCAR_ADMIN_PASSWORD_FAMILY_A` (when `LOCATION_APP=traccar`)
- `PARENT_PASSWORD_FAMILY_A` / `KID_PASSWORD_FAMILY_A` (family layer test users)

`remote-run.sh` passes them in a root-only `remote.env` on the VM (never printed).

Federation and verification:

```bash
./scripts/spark/configure-federation-pair.sh "<ip-a>" "<ip-b>"
./scripts/spark/verify-federation-e2e.sh \
  family-a family-b \
  family-a.family.test family-b.family.test \
  alice bob matrix.org

./scripts/spark/verify-calendar-e2e.sh family-a family-a.family.test
./scripts/spark/verify-calendar-e2e.sh family-b family-b.family.test

./scripts/spark/verify-events-e2e.sh \
  family-a family-b \
  family-a.family.test family-b.family.test \
  mobilizon.fr
```

Participant usernames default to alice/bob (federation) and parent/kid (calendar, events).
Override per name via CLI args (verify-federation-e2e.sh args 5–6, verify-calendar-e2e.sh
args 3–4, verify-events-e2e.sh arg 6) or in `config/local.env`: `TWS_ALICE_USER`,
`TWS_BOB_USER`, `TWS_PARENT_USER`, `TWS_KID_USER`. The family household itself is the
`TWS_FAMILY_USERS` list (see `scripts/lib/family_users.sh` — `--users` flag on the VM
scripts, `TWS_FAMILY_OWNER`/`TWS_FAMILY_PARENTS`/`TWS_FAMILY_KIDS` splits); the calendar
and events verifiers default their organizer to that list's owner and the attendee to
its first kid. Passwords for custom names come from `$<USERNAME>_PASSWORD` (e.g.
`MOM_DAD_PASSWORD` for user `mom.dad`) or `<USERNAME>_PASSWORD_<NODE>` keys in
`passwords.env`; `ensure-node-secrets.sh` generates the latter from the same overrides,
so a lab can run with realistically-named household members without touching the classic
alice/bob/parent/kid flow.

Matrix verification uses the **lab CA** for TLS when present (otherwise the system trust store), has **bob join** the room, polls `/messages`, and expects **`M_FORBIDDEN`** / federation denied for `matrix.org`.

Calendar verification checks CalDAV login and a parent → kid invite accept round trip on each node (see [CALENDAR.md](CALENDAR.md)).

Mobilizon verification checks **public** `/.well-known/nodeinfo` (no SSO redirect), syncs trusted instances as **`twsowner`** (YunoHost admin password from secrets), creates an event as **`parent`** with a default actor, waits for the federated **UUID** on family-b before RSVP, and **passively** checks `mobilizon.fr` is not followed (no outbound probe during sync).

Before federation tests, ensure VMs resolve each other’s `mobilizon.*` hostnames (`sync-all-vm-peer-hosts.sh` above).

### Manual steps on spark

With `LAB_PASSWORD=dummydummy` in `config/local.env` (≥8 characters), after both nodes reach `family-init.sh`:

1. Run **`./scripts/spark/sync-all-vm-peer-hosts.sh`** so each VM can reach the peer’s `mobilizon.*` hostname.
2. Confirm apps: `yunohost app list` on each VM should include **nextcloud** and **mobilizon** (re-run `yunohost-family-apps.sh` / `install-mobilizon.sh` if needed).
3. Run `configure-federation-pair.sh` (Matrix + Mobilizon sync) if not already linked via dashboard invite. Failures here are fatal (Mobilizon TLS/sync must succeed).
4. Run the three verify scripts above; fix DNS (`apply-private-dns.sh`) on spark if HTTPS to `nextcloud.*` or `mobilizon.*` fails. The verifiers use the lab CA when found (`TW_STACK_LAB_CA_DIR`, `lab-certs/`, or `TWS_CA_BUNDLE`) and otherwise fall back to the **system trust store** — verification is never disabled. Set `TWS_REQUIRE_LAB_CA=1` to make a missing lab CA a hard error again.
5. Optional UI: `https://family-a.family.test/family/` → **CalDAV setup** and **open events**; child chat rules → toggle **Events** for a kid (Mobilizon LDAP login after SSO if prompted).

---

## One-box installer in the lab

You can provision a **single** test VM without driving it from spark via
`remote-run.sh` — useful when the VM has no root SSH key from your laptop yet.

1. Create the VM as usual: `./scripts/spark/create-vm.sh` (or
   `deploy-test-nodes.sh`), note its IP.
2. Issue lab certs for the node's domain (on spark):

   ```bash
   ./scripts/lab-ca/issue-domain-cert.sh family-c.family.test
   ```

   Stage certs under `~/.tinywebstack-secrets/lab-ca/certs/` (same layout
   `remote-run.sh` rsyncs to `lab-certs/`).

3. Copy the git checkout and certs onto the VM (rsync/scp), or clone on the VM
   and copy the `certs/<fqdn>/` tree plus `lab-ca.crt.pem` into a directory
   referenced by `TWS_LAB_CERTS_DIR`.

4. On the VM, write `tinyweb.env`:

   ```bash
   TWS_DOMAIN=family-c.family.test
   TWS_NODE_NAME=family-c
   TWS_MODE=lab
   LAB_PASSWORD=dummydummy
   TWS_LAB_CERTS_DIR=/path/to/lab-certs
   TWS_PEERS_HOSTS_FILE=/path/to/peers.hosts   # optional; from sync-vm-peer-hosts
   ```

5. Run:

   ```bash
   sudo ./scripts/install-tinyweb.sh --config ./tinyweb.env
   ```

6. Link households from the dashboard invite UI on an existing node as usual.

**Verifiers on spark** still expect per-node keys in
`~/.tinywebstack-secrets/passwords.env`. After a one-box install, copy
`/etc/tinywebstack/secrets/install.env` from the VM to a temp file on spark
(mode 600) and point verifiers at it, e.g.:

```bash
# On spark — map install.env keys to verifier names (example for family-c):
TW_STACK_SECRETS_FILE=/tmp/family-c-install.env \
  PARENT_PASSWORD_FAMILY_C="$(grep '^PARENT_PASSWORD=' /tmp/family-c-install.env | cut -d= -f2-)" \
  ./scripts/spark/verify-calendar-e2e.sh family-c family-c.family.test
```

Easiest path: translate `PARENT_PASSWORD` → `PARENT_PASSWORD_FAMILY_C` (and
the same for `KID_PASSWORD`, `YUNOHOST_ADMIN_PASSWORD`, alice/bob, etc.) into
a scratch `passwords.env` derived from the VM's `install.env` without printing
values.

---

## Spark upgrade runbook (existing lab VMs)

Use this after pulling a release that includes the SQLite permissions store
(PR #29/#30) and dashboard federation UI (L2.2). Example IPs for the default
lab pair: `IP_A=192.168.122.47`, `IP_B=192.168.122.18`. Set `DOMAIN_A`,
`DOMAIN_B`, `NODE_A=family-a`, `NODE_B=family-b` to match your `config/nodes.conf`.

From the repo on **spark** (control machine), with `config/nodes.conf` and secrets
already in place:

```bash
IP_A=192.168.122.47
IP_B=192.168.122.18
DOMAIN_A=family-a.family.test
DOMAIN_B=family-b.family.test
NODE_A=family-a
NODE_B=family-b

# 0 — sync scripts to both nodes (first step; no separate "true" probe script)
./scripts/vm/remote-run.sh "$IP_A" family-groups.sh
./scripts/vm/remote-run.sh "$IP_B" family-groups.sh

# 1 — Synapse module + family dashboard (main domain only)
./scripts/vm/remote-run.sh "$IP_A" install-family-module.sh "$DOMAIN_A"
./scripts/vm/remote-run.sh "$IP_B" install-family-module.sh "$DOMAIN_B"
./scripts/vm/remote-run.sh "$IP_A" install-family-dashboard.sh "$DOMAIN_A"
./scripts/vm/remote-run.sh "$IP_B" install-family-dashboard.sh "$DOMAIN_B"

# 2 — seed permissions DB from legacy policy (per node)
./scripts/vm/remote-run.sh "$IP_A" family-permissions-seed.sh "$DOMAIN_A" "$NODE_A"
./scripts/vm/remote-run.sh "$IP_B" family-permissions-seed.sh "$DOMAIN_B" "$NODE_B"

# 3 — federation state file for dashboard trusted-domain UI
./scripts/vm/remote-run.sh "$IP_A" family-federation-state-seed.sh "$DOMAIN_A"
./scripts/vm/remote-run.sh "$IP_B" family-federation-state-seed.sh "$DOMAIN_B"

# 4 — Mobilizon admin API password (stdin; never on argv)
pw="$(grep '^YUNOHOST_ADMIN_PASSWORD_FAMILY_A=' ~/.tinywebstack-secrets/passwords.env | cut -d= -f2-)"
printf '%s' "$pw" | ./scripts/vm/remote-run.sh "$IP_A" tws-store-mobilizon-admin-password.sh
pw="$(grep '^YUNOHOST_ADMIN_PASSWORD_FAMILY_B=' ~/.tinywebstack-secrets/passwords.env | cut -d= -f2-)"
printf '%s' "$pw" | ./scripts/vm/remote-run.sh "$IP_B" tws-store-mobilizon-admin-password.sh
unset pw

# 5 — Matrix + Mobilizon federation sync, then kid events LDAP/SSO from the DB
./scripts/vm/remote-run.sh "$IP_A" family-sync-federation.sh "$DOMAIN_A"
./scripts/vm/remote-run.sh "$IP_B" family-sync-federation.sh "$DOMAIN_B"
./scripts/vm/remote-run.sh "$IP_A" family-events-perms.sh
./scripts/vm/remote-run.sh "$IP_B" family-events-perms.sh

# 6 — verifiers (federation: run on spark, not inside unshare)
./scripts/spark/verify-federation-e2e.sh \
  "$NODE_A" "$NODE_B" \
  "$DOMAIN_A" "$DOMAIN_B" \
  alice bob matrix.org
./scripts/spark/verify-calendar-e2e.sh "$NODE_A" "$DOMAIN_A"
./scripts/spark/verify-calendar-e2e.sh "$NODE_B" "$DOMAIN_B"
./scripts/spark/verify-events-e2e.sh \
  "$NODE_A" "$NODE_B" \
  "$DOMAIN_A" "$DOMAIN_B"
```

Calendar and events verifiers need **spark** to resolve `nextcloud.*` / `mobilizon.*`
lab hostnames; run `sudo ./scripts/spark/apply-private-dns.sh` once if you have not
already.

`remote-run.sh` rsyncs `config/nodes.conf` when present so the dashboard
**Federation** page lists peer nodes. Re-run step 0 after editing `nodes.conf`.

---

## YunoHost 12 user creation (manual)

```bash
sudo yunohost user create alice -F "Alice Test" -p '…' -d family-a.family.test
```

(`--firstname` / `--lastname` are not available on YunoHost 12.)

---

## Federation / Synapse notes

- Snippet: `/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml` (mode **640** `root:synapse`).
- Lab CA PEM: `/etc/matrix-synapse/tinywebstack-lab-ca.pem` (not under `conf.d/`).
- Service unit: **`synapse`** (not `matrix-synapse`).
- Private libvirt IPs: `ip_range_whitelist` (default `192.168.122.0/24`, override `FEDERATION_IP_RANGE_WHITELIST`).

---

## Local validation

```bash
./scripts/validate.sh
```

---

## Teardown

```bash
./scripts/spark/destroy-vm.sh family-a --remove-disk
./scripts/spark/destroy-vm.sh family-b --remove-disk
sudo sed -i '/tinywebstack-test-nodes-begin/,/tinywebstack-test-nodes-end/d' /etc/hosts
```
