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

Matrix verification uses the **lab CA** for TLS, has **bob join** the room, polls `/messages`, and expects **`M_FORBIDDEN`** / federation denied for `matrix.org`.

Calendar verification checks CalDAV login and a parent → kid invite accept round trip on each node (see [CALENDAR.md](CALENDAR.md)).

Mobilizon verification logs in as **`parent`** (SSO) on each node, syncs trusted instances, creates an event on family-a and RSVPs from family-b, and checks a **non-trusted** probe host (`mobilizon.fr` by default) is not approved.

### Manual steps on spark

With `LAB_PASSWORD=dummydummy` in `config/local.env` (≥8 characters), after both nodes reach `family-init.sh`:

1. Confirm apps: `yunohost app list` on each VM should include **nextcloud** and **mobilizon** (re-run `yunohost-family-apps.sh` / `install-mobilizon.sh` if needed).
2. Run `configure-federation-pair.sh` (Matrix + Mobilizon sync) if not already linked via dashboard invite.
3. Run the three verify scripts above; fix DNS (`apply-private-dns.sh`) if HTTPS to `nextcloud.*` or `mobilizon.*` fails.
4. Optional UI: `https://family-a.family.test/family/` → **CalDAV setup** and **open events**; child chat rules → toggle **Events** for a kid.

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
