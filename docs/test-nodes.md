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
| Location (default) | `traccar.family-a.family.test` | Catalog app; set `LOCATION_APP=owntracks` to try OwnTracks (+ apt key prep) |

`apply-private-dns.sh` adds all of these names to spark’s `/etc/hosts`. Mirror peer names on each VM as needed.

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
./scripts/vm/remote-run.sh "$IP" yunohost-family-apps.sh "$DOMAIN"
./scripts/vm/remote-run.sh "$IP" create-matrix-test-users.sh "$DOMAIN" "$NODE_NAME"
```

Passwords are generated on spark by `ensure-node-secrets.sh` into `~/.tinywebstack-secrets/passwords.env`:

- `YUNOHOST_ADMIN_PASSWORD_FAMILY_A`
- `ALICE_PASSWORD_FAMILY_A` / `BOB_PASSWORD_FAMILY_B` (etc.)

`remote-run.sh` passes them in a root-only `remote.env` on the VM (never printed).

Federation:

```bash
./scripts/spark/configure-federation-pair.sh "<ip-a>" "<ip-b>"
./scripts/spark/verify-federation-e2e.sh \
  family-a family-b \
  family-a.family.test family-b.family.test \
  alice bob matrix.org
```

Verification uses the **lab CA** for TLS, has **bob join** the room, polls `/messages`, and expects **`M_FORBIDDEN`** / federation denied for `matrix.org`.

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
