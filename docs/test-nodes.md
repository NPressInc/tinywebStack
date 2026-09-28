# YunoHost test nodes on `spark` (milestones 1 and 3)

Headless KVM/libvirt VMs on William's Ubuntu host **spark**, YunoHost + Synapse/Element/OwnTracks, and Matrix federation with an allowlist.

## Paths on spark (important)

| Purpose | Path |
|--------|------|
| Git checkout | e.g. `~/Documents/codingProj/tinywebStack` |
| VM disks & cloud-init seeds | `/var/lib/libvirt/images/tinywebstack` (default) |
| Cloud image cache | `~/.tinywebstack/images` |
| Passwords & lab CA (not in git) | `~/.tinywebstack-secrets/` (`passwords.env`, `lab-ca/`) |

Do **not** put the repo inside `~/tinywebstack` if that directory is used for VM data.

## Architecture

```text
spark (Ubuntu 24.04, aarch64 or amd64, KVM)
├── tws-family-a  →  family-a.family.test
└── tws-family-b  →  family-b.family.test
         Matrix federation + shared lab CA (TLS)
```

Provisioning SSH user: **`twsadmin`** (not `admin`). YunoHost postinstall uses the same username by default so SSH stays in the `admins` group.

### Location app: OwnTracks

Family-oriented, YunoHost-packaged; see [PLAN.md](../PLAN.md).

### DNS and TLS

- **DNS:** private `.family.test` names via `/etc/hosts` on spark and peer entries on each VM (`apply-private-dns.sh`).
- **TLS:** shared **lab CA** (`scripts/lab-ca/`) issues certs for each domain; YunoHost installs them via `yunohost-lab-tls.sh`. Synapse trusts the same CA via `federation_custom_ca_list` in `conf.d` (fallback: `federation_verify_certificates: false` only if lab CA is missing).

---

## Prerequisites on `spark`

Add your user to **libvirt** and **kvm**, then log out and back in:

```bash
sudo usermod -aG libvirt,kvm "$USER"
```

Install packages (architecture-specific):

```bash
sudo apt update
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" = amd64 ]; then
  sudo apt install -y qemu-kvm libvirt-daemon-system virtinst virt-viewer \
    genisoimage cloud-image-utils curl rsync qemu-utils
else
  # arm64 (spark): qemu-kvm meta-package may be unavailable
  sudo apt install -y qemu-system-arm qemu-efi-aarch64 qemu-utils \
    libvirt-daemon-system virtinst virt-viewer \
    genisoimage cloud-image-utils curl rsync
fi
```

Libvirt URI (non-root): scripts set this automatically; you can export it in `config/local.env`:

```bash
LIBVIRT_DEFAULT_URI=qemu:///system
```

VM disks default to **`/var/lib/libvirt/images/tinywebstack`** so `libvirt-qemu` can read them (home dirs with mode `750` break session-based storage under `$HOME`).

From the **repo root**:

```bash
cd ~/Documents/codingProj/tinywebStack   # your clone

cp config/nodes.conf.example config/nodes.conf
cp config/defaults.env.example config/local.env   # optional overrides
mkdir -p ~/.tinywebstack-secrets && chmod 700 ~/.tinywebstack-secrets
```

Ensure `~/.ssh/id_ed25519.pub` exists (or set `ADMIN_SSH_PUBKEY` in `local.env`).

---

## Step 1 — Lab CA and VMs

```bash
chmod +x scripts/**/*.sh scripts/*.sh
./scripts/spark/stage-lab-certs.sh
./scripts/spark/deploy-test-nodes.sh
```

Wait for cloud-init, then:

```bash
virsh domifaddr tws-family-a
virsh domifaddr tws-family-b
sudo ./scripts/spark/apply-private-dns.sh
```

Add peer `/etc/hosts` lines on each VM (SSH as **`twsadmin`**).

---

## Step 2 — YunoHost on each VM

```bash
export NODE_IP=192.168.122.X
export DOMAIN=family-a.family.test
export NODE_NAME=family-a

# Optional: predefine admin password (otherwise written to ~/.tinywebstack-secrets/passwords.env)
# export YUNOHOST_ADMIN_PASSWORD='...'

./scripts/vm/remote-run.sh "twsadmin@${NODE_IP}" yunohost-bootstrap.sh "${DOMAIN}" "${NODE_NAME}"
```

Installer URL: **`https://install.yunohost.org`**, unattended via `bash -s -- -a`, then **`yunohost tools postinstall`** with CLI flags (no prompts). Passwords are **never printed**; they go to `TW_STACK_SECRETS_FILE` (default `~/.tinywebstack-secrets/passwords.env`).

Repeat for family-b.

---

## Step 3 — Apps and test users

```bash
./scripts/vm/remote-run.sh "twsadmin@${NODE_IP}" yunohost-family-apps.sh "${DOMAIN}"
```

Create Matrix test users and store passwords in the secrets file, e.g.:

```bash
# On the VM
ALICE_PW="$(openssl rand -base64 18)"
BOB_PW="$(openssl rand -base64 18)"
sudo yunohost user create alice --firstname Alice --lastname Test --password "$ALICE_PW"
sudo yunohost user create bob --firstname Bob --lastname Test --password "$BOB_PW"
```

On spark, append to `~/.tinywebstack-secrets/passwords.env` (mode `600`):

```bash
ALICE_PASSWORD_FAMILY_A='...'
BOB_PASSWORD_FAMILY_B='...'
```

---

## Step 4 — Federation allowlist

```bash
./scripts/spark/configure-federation-pair.sh "twsadmin@<ip-a>" "twsadmin@<ip-b>"
```

Config lives in **`/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml`** (not edited into `homeserver.yaml`).

---

## Step 5 — Verification

### Automated (Client-Server API)

From spark, after alice/bob exist and secrets are set:

```bash
./scripts/spark/verify-federation-e2e.sh \
  family-a family-b \
  family-a.family.test family-b.family.test \
  alice bob matrix.org
```

This logs in on both homeservers, creates a federated DM, delivers a message, and checks that inviting `@someone:matrix.org` fails (allowlist).

### Manual (Element)

Same flow as before: Element → DM across domains; confirm `matrix.org` invites fail. Check `journalctl -u matrix-synapse -f` for whitelist denials.

---

## Teardown

```bash
./scripts/spark/destroy-vm.sh family-a --remove-disk
./scripts/spark/destroy-vm.sh family-b --remove-disk
sudo sed -i '/tinywebstack-test-nodes-begin/,/tinywebstack-test-nodes-end/d' /etc/hosts
```

---

## Local validation

```bash
./scripts/validate.sh
```

Runs `bash -n`, downloads **shellcheck** static binary if needed, `DRY_RUN` deploy (does not overwrite your `config/nodes.conf`), and YAML lint.

---

## Single VM later

Unchanged from [PLAN.md](../PLAN.md): two federated homeservers ⇒ two VMs (or accept same-server testing without federation).
