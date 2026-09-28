# YunoHost test nodes on `spark` (milestones 1 and 3)

This guide is for William: stand up **two** headless YunoHost VMs on the Ubuntu host `spark` using KVM/libvirt, install the family app set (Synapse, Element, location), and prove **Matrix federation with an allowlist** between the nodes.

You cannot run GUI tools on `spark`; everything is SSH and CLI.

## Architecture

```text
spark (Ubuntu + KVM)
├── tws-family-a  →  family-a.family.test  (YunoHost + Synapse + Element + OwnTracks)
└── tws-family-b  →  family-b.family.test  (same stack)
         Matrix federation (allowlist: only each other's domain)
```

Scripts live under `scripts/`. Parameters live in `config/nodes.conf` (copy from `config/nodes.conf.example`) and optional overrides in `config/local.env` (never commit secrets).

### Location app choice: OwnTracks

We install **OwnTracks** (not Traccar):

- OwnTracks matches the family use case (opt-in location sharing from phones, parent-controlled accounts via YunoHost users).
- Traccar targets fleet/GPS device tracking and is heavier to align with the family permission model in [PLAN.md](../PLAN.md).
- OwnTracks has a [YunoHost app package](https://github.com/YunoHost-Apps/owntracks_ynh).

### Private DNS and TLS (documented choice)

| Concern | Approach |
|--------|----------|
| **DNS** | Use the `.family.test` names from `config/nodes.conf.example`. They are not public DNS. On `spark`, run `scripts/spark/apply-private-dns.sh` (updates `/etc/hosts` from libvirt DHCP leases). Mirror the same lines in each VM's `/etc/hosts` for the **peer** domain, or run a small dnsmasq on `spark` if you prefer one place to maintain records. |
| **TLS** | YunoHost expects HTTPS. Public Let's Encrypt will **not** work for private names. On each VM, after `yunohost domain add`, install a **self-signed** certificate (see bootstrap script). Trust is limited to your test clients: import the cert, use Element on desktop, or accept browser warnings. This is intentional for lab nodes. |

Federation uses HTTPS between homeserver names; both nodes must resolve and trust each other's certificates (or use clients that accept your CA/self-signed setup).

### Single VM later (two domains / two “families”)

Scripts are structured by **node name** in `config/nodes.conf`, not hard-coded for two VMs:

- **Two VMs (recommended for milestone 3):** Two independent YunoHost installs, two Synapse homeservers — matches production “two households”.
- **One VM, two domains:** Standard YunoHost supports **multiple domains** on one install but **one Synapse app** (one Matrix homeserver). Users on both domains are still on the **same** server; you do **not** need federation to message within that server. That layout does **not** prove cross-household federation.
- **One VM, two Synapse instances:** Not supported by the catalog; would fight YunoHost’s one-app-per-service model. Not recommended.

To collapse infrastructure while keeping federation proof, keep **two logical nodes** (two VMs) or accept same-server testing without federation.

---

## Prerequisites on `spark`

Run on `spark` as a user in the `libvirt` group:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst virt-viewer \
  genisoimage cloud-image-utils curl rsync

# Clone or pull tinywebStack repo
cd ~/tinywebstack   # path is your choice; scripts use TW_STACK_ROOT from cwd

cp config/nodes.conf.example config/nodes.conf
cp config/defaults.env.example config/local.env   # edit paths if needed
```

Ensure `~/.ssh/id_ed25519.pub` exists (or set `ADMIN_SSH_PUBKEY` in `local.env`).

---

## Step 1 — Create both VMs (idempotent)

From the repo root on `spark`:

```bash
chmod +x scripts/**/*.sh scripts/*.sh
./scripts/spark/deploy-test-nodes.sh
```

Wait for cloud-init to finish, then get IPs:

```bash
virsh domifaddr tws-family-a
virsh domifaddr tws-family-b
```

Update private DNS on `spark`:

```bash
sudo ./scripts/spark/apply-private-dns.sh
```

Copy peer host entries onto each VM (SSH as `admin`), e.g. on **family-a**:

```bash
# On VM family-a — add family-b's IP and name
sudo tee -a /etc/hosts <<EOF
<family-b-ip>  family-b.family.test
EOF
```

Repeat symmetrically on family-b.

---

## Step 2 — Install YunoHost on each VM

From `spark`, for each node (replace IP and domain):

```bash
export NODE_IP=192.168.122.X
export DOMAIN=family-a.family.test

ssh admin@${NODE_IP} 'curl -sSf https://install.yunohost.fr | bash'

# Copy scripts and bootstrap (password generated if not set)
./scripts/vm/remote-run.sh admin@${NODE_IP} yunohost-bootstrap.sh "${DOMAIN}"
```

Save the generated admin password. Repeat for `family-b.family.test`.

Optional: set `YUNOHOST_ADMIN_PASSWORD` in the environment when bootstrapping if you want a chosen password (do not commit it).

---

## Step 3 — Install Synapse, Element, OwnTracks

On each VM via `spark`:

```bash
./scripts/vm/remote-run.sh admin@${NODE_IP} yunohost-family-apps.sh "${DOMAIN}"
```

On each node, create test users (example):

```bash
sudo yunohost user create alice --firstname Alice --lastname Test --password "$(openssl rand -base64 16)"
sudo yunohost user create bob --firstname Bob --lastname Test --password "$(openssl rand -base64 16)"
```

Grant app permissions as needed (`yunohost user permission list`, `yunohost user permission update ...`).

---

## Step 4 — Federation allowlist (milestone 3)

From `spark`, once both nodes are up:

```bash
./scripts/spark/configure-federation-pair.sh admin@<ip-a> admin@<ip-b>
```

This sets `federation_domain_whitelist` on each Synapse so **only the peer domain** is allowed.

---

## Step 5 — Verification procedure

### A. Allowed federation (user on A messages user on B)

1. Log into Element on **family-a** as `@alice:family-a.family.test` (client must use homeserver `https://family-a.family.test`).
2. Start a direct message to `@bob:family-b.family.test`.
3. On **family-b**, log in as Bob and confirm the message arrives.
4. On either server: `sudo journalctl -u matrix-synapse -f` — you should see successful federation traffic between the two domains (no “not in whitelist” errors).

### B. Non-allowlisted server refused

Pick a domain **not** in the whitelist (e.g. `matrix.org` or a fake `evil.family.test` that resolves to nothing):

1. From VM **family-a**, try to reach a third homeserver’s federation API:

   ```bash
   curl -sS "https://matrix.org/_matrix/federation/v1/version" | head
   ```

2. In Element on family-a, attempt to invite `@someone:matrix.org` to a room — with the whitelist, Synapse should **refuse outbound federation** to non-listed domains (check Synapse logs for whitelist denial).

3. Optional automated hint from `spark`:

   ```bash
   ./scripts/spark/verify-federation.sh family-a.family.test family-b.family.test matrix.org
   ```

**Success criteria:** Alice ↔ Bob works across domains; federation to `matrix.org` (or other non-allowlisted servers) does not establish.

---

## Teardown

```bash
./scripts/spark/destroy-vm.sh family-a --remove-disk
./scripts/spark/destroy-vm.sh family-b --remove-disk
sudo sed -i '/tinywebstack-test-nodes-begin/,/tinywebstack-test-nodes-end/d' /etc/hosts
```

---

## Local validation (without `spark`)

In CI or a dev container:

```bash
./scripts/validate.sh
```

This runs `bash -n`, optional `shellcheck`, renders a cloud-init ISO with `DRY_RUN`, and parses the Synapse YAML example. It does **not** run `virt-install` or YunoHost.

---

## What this agent could not test

- Real `virt-install` / libvirt on `spark`
- YunoHost installer and app installs
- Live Matrix federation or TLS trust on your LAN
- OwnTracks mobile publish (requires phones and firewall rules)

Run `./scripts/validate.sh` where you develop; run the steps above on `spark` for end-to-end proof.
