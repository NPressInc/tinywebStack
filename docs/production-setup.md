# Production setup runbook (S5.2)

Take a fresh machine (real hardware or VPS) to a working tinyWebStack **family
node**: YunoHost 12 + Synapse/Element + OwnTracks (or Traccar) + Nextcloud
CalDAV + Mobilizon + the parent dashboard at `https://<main-domain>/family/`,
with Let's Encrypt TLS and real family accounts.

The lab path ([test-nodes.md](test-nodes.md)) is disposable KVM VMs on `spark`
with a private CA and `LAB_PASSWORD`. For upgrading **existing** lab VMs after
the SQLite permissions / federation-dashboard release, use the
[Spark upgrade runbook](test-nodes.md#spark-upgrade-runbook-existing-lab-vms)
section in that doc. This runbook is the production path:
public DNS, Let's Encrypt, random per-account secrets. The `scripts/vm/`
scripts are shared between both paths; `scripts/spark/` is lab-only **except**
`remote-run.sh` (in `scripts/vm/`) and `configure-federation-pair.sh`, which
are control-machine-generic — they take any SSH target and read
`config/nodes.conf`. Where a step still needs a manual workaround because a
script is lab-coupled, it says so; all such gaps are collected in
[Known gaps for v1.1](#known-gaps-for-v11).

**Convention used below:** main domain `home.example.com`, node id `home-a`
(second household: `home.b.example` / `home-b`), control machine = the laptop
or server you run the scripts from. Node ids must match
`^[a-zA-Z][a-zA-Z0-9_-]*$` (see `scripts/lib/secrets.sh`).

---

## 0. What you end up with (per node)

| Service | Hostname | Notes |
|---------|----------|-------|
| YunoHost main + portal | `home.example.com` | postinstall domain; portal redirects `/` → `/family/` |
| Family dashboard | `https://home.example.com/family/` | `parents` group only (YunoHost SSO) |
| Synapse | `matrix.home.example.com` | `server_name=home.example.com` → `@user:home.example.com` |
| Element (admin web client) | `element.home.example.com` | parents use Element X on phones |
| Location (default) | `owntracks.home.example.com` | set `LOCATION_APP=traccar` for catalog fallback (`traccar.` host) |
| Nextcloud CalDAV | `nextcloud.home.example.com` | phones use CalDAV directly ([CALENDAR.md](CALENDAR.md)) |
| Mobilizon events | `mobilizon.home.example.com` | SSO/LDAP ([EVENTS.md](EVENTS.md)) |

All six names **must** resolve to the node (see §1.2).

### Where the code lives on the node

`remote-run.sh` rsyncs the repo into a **flat deploy tree** at
`/opt/tinywebstack` on the node (`vm/`, `lib/`, `defaults.env`, `family/`,
`brand/` at the top level — not the git layout `scripts/…`). **Do not** run
`scripts/vm/*.sh` directly from a git clone on the node: those scripts resolve
`TW_STACK_ROOT` to `<clone>/scripts`, where `defaults.env`, `family/`, and
`brand/` are not visible, and they fail. Always drive the node from the
control machine with `scripts/vm/remote-run.sh` (§2.2).

---

## 1. Prerequisites

### 1.1 Machine

- Any x86-64 or arm64 box you control: mini-PC/NUC/Raspberry Pi 4+ (4 GB RAM
  minimum; **8 GB strongly recommended** — Synapse + Nextcloud + Mobilizon +
  OwnTracks together are the heavy part), or a 2-vCPU / 8 GB VPS.
- ≥ 40 GB free disk (base OS + app data; Nextcloud and Synapse grow).
- Debian 12 (bookworm) — YunoHost 12's supported base. Either the official
  YunoHost 12 installer image (skips §2.1) or a **minimal Debian 12** install
  (`sudo` access, SSH reachable from your LAN/admin network, nothing else).
- UPS or at least reliable power if this is the family's canonical data.

### 1.2 Domain and DNS

You need one domain (or sub-domain) you control DNS for. Register delegation
of `home.example.com` (or use `nohost.me`/`anytld.me` free domains from
YunoHost — see §1.3 for DynDNS).

Create **AAAA** records alongside **A** records wherever you have IPv6 —
Matrix and Mobilizon federation between households breaks more often over
IPv4-only + CGNAT.

| Record | Value |
|--------|-------|
| `A  home.example.com` | node public IPv4 |
| `AAAA home.example.com` | node public IPv6 (if available) |
| `A/AAAA matrix.home.example.com` | same |
| `A/AAAA element.home.example.com` | same |
| `A/AAAA owntracks.home.example.com` | same (or `traccar.` if `LOCATION_APP=traccar`) |
| `A/AAAA nextcloud.home.example.com` | same |
| `A/AAAA mobilizon.home.example.com` | same |

A wildcard `*.home.example.com` A/AAAA covers all of these except the apex.
Check propagation from **outside** your LAN:

```bash
for d in "" matrix. element. owntracks. nextcloud. mobilizon.; do
  dig +short "${d}home.example.com" A
done
```

**Expected:** the node's public IP (or its IPv6) for all six.
*If this fails:* fix DNS at the registrar; do not proceed — Let's Encrypt
(§3) and federation (§7) both resolve these names from the public internet.

**MX:** not needed. This stack installs no mail server; only add MX records if
you later install `mail_ynh` (then also run `yunohost domain dns-conf
home.example.com` and follow `yunohost dns whois-info`).

### 1.3 ISP / network path

Choose one:

- **Static IP VPS or business line:** just point DNS (§1.2) and go.
- **Residential ISP, dynamic IP:** two options —
  1. **YunoHost DynDNS (easiest):** register a free `nohost.me`-style domain
     during postinstall; YunoHost keeps DNS in sync and updates it on boot and
     by cron (`yunohost-portal-api`/`update_url` mechanism; verify with
     `sudo cat /etc/yunohost/dyndns`). Caveat: `yunohost-bootstrap.sh` passes
     `--ignore-dyndns` (§2.4), so use a **custom domain + your registrar's
     API/DDNS client** (e.g. `ddclient`, `cloudflare-ddns`, `odoh`) or run
     `sudo yunohost dns update` after IP changes. *If this fails (stale IP):*
     DynDNS state lives in `/etc/yunohost/dyndns`; re-register the domain from
     the admin panel (Domains → DynDNS) and re-run `sudo yunohost dns update`.
  2. **Router port-forward (CGNAT-proof enough for most ISPs):** forward
     **TCP 80 and 443** from your router to the node's LAN IP. TCP 80 must
     reach nginx for the ACME HTTP-01 challenge (§3). Do **not** also run
     another web server or NAS DMZ on those ports. Enable NAT loopback/hairpin
     or add the FQDNs to the node's `/etc/hosts` (`127.0.0.1` lines) so the
     node can reach its own FQDNs — Let's Encrypt's self-check does this.
  - Upstream **bandwidth** matters: Mobilizon/Synapse federation is chatty;
    100 Mbps down / 20 Mbps up is workable, symmetric fiber is nicer.
  - Check your ISP doesn't block port 25/80/443 for residential lines:
    `curl -4 ifconfig.me` on the node, then `nmap -p 80,443 <that IP>` from a
    phone on cellular Wi‑Fi off. **Expected:** both `open`.

### 1.4 Control machine

The machine that drives the node via SSH (your laptop is fine — the "spark"
name in `scripts/spark/` is just the lab's control box; `remote-run.sh` works
from anywhere). Needs: `git`, `rsync`, `ssh`, `python3`, and outbound
access to the node on port 22.

---

## 2. Install Debian and bootstrap YunoHost

### 2.1 Fresh OS

Flash the Debian 12 netinst (or your VPS's Debian 12 image). Minimal install,
no desktop tasks, **enable SSH**. Create one admin user with sudo. Set a
static LAN IP or DHCP reservation.

### 2.2 Root SSH for `remote-run.sh`

`remote-run.sh` defaults to `root@host` (`REMOTE_SSH_USER=root`) and uses
`BatchMode=yes` + pinned host keys, so password auth will not work. From the
node's console:

```bash
sudo apt update && sudo apt install -y openssh-server rsync sudo
sudo passwd -l root                      # no password — key only
sudo install -d -m 700 -o root -g root /root/.ssh
echo '<your public key>' | sudo tee -a /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
```

Debian ships `PermitRootLogin prohibit-password` — the key alone is enough.

**Expected:** `ssh -o BatchMode=yes root@<node-ip> hostname` prints the
hostname with no prompt.
*If this fails:* check `sshd -T | grep permitrootlogin` (must not be `no`),
and file permissions (`/root`, `/root/.ssh`, `authorized_keys` must not be
group-writable).

### 2.3 Control-machine repo + config

```bash
git clone https://github.com/NPressInc/tinywebStack.git ~/Documents/codingProj/tinywebStack
cd ~/Documents/codingProj/tinywebStack
cp config/nodes.conf.example config/nodes.conf
$EDITOR config/nodes.conf        # one row per household — see below
cp config/defaults.env.example config/local.env   # git-ignored; never committed
$EDITOR config/local.env
```

`config/nodes.conf` — the RAM/VCPUS/DISK columns are ignored off-libvirt; the
**first two rows** are what `configure-federation-pair.sh` reads:

```
home-a   home.example.com   4096 2 32
home-b   home.b.example     4096 2 32     # add when you link a 2nd household
```

`config/local.env` — production values:

```bash
ADMIN_SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub"
REMOTE_SSH_USER="root"
YUNOHOST_ADMIN_USER="twsowner"
LOCATION_APP="owntracks"          # or "traccar"
EVENTS_APP="mobilizon"
TWS_LAB_TLS_INSECURE="0"          # CRITICAL: keep production TLS verification on (§5.4)
# DO NOT set LAB_PASSWORD here — that is lab-only and shares one password
# across every account. Leaving it unset makes ensure-node-secrets.sh
# generate a unique random password per secret (openssl rand).
```

`TWS_LAB_TLS_INSECURE=0` must be set **before** `install-family-dashboard.sh`
first runs: the installer writes `TWS_LAB_TLS_INSECURE=${TWS_LAB_TLS_INSECURE:-1}`
into `/etc/tinywebstack/dashboard.env` and never revisits that key on reruns.

Generate the per-node secrets on the control machine (source of truth:
`~/.tinywebstack-secrets/passwords.env`, mode 600):

```bash
scripts/spark/ensure-node-secrets.sh
grep -o '^[A-Z_]*' ~/.tinywebstack-secrets/passwords.env
```

**Expected:** keys like `YUNOHOST_ADMIN_PASSWORD_HOME_A`,
`PARENT_PASSWORD_HOME_A`, `KID_PASSWORD_HOME_A`, `ALICE_PASSWORD_HOME_A`,
… with random values (no `LAB_PASSWORD`). `remote-run.sh` pushes the right
ones to the node in a root-only `remote.env` per invocation and deletes it
after; nothing is ever printed.
*If this fails:* YunoHost rejects passwords < 8 chars — delete the offending
key from `passwords.env` and re-run.

### 2.4 Bootstrap YunoHost

```bash
IP=<node-ip>
scripts/vm/remote-run.sh "$IP" yunohost-bootstrap.sh home.example.com home-a
```

This runs `scripts/vm/yunohost-bootstrap.sh` on the node as root: installs
YunoHost (`curl -sSf https://install.yunohost.org | bash -s -- -a`), runs
`yunohost tools postinstall --domain home.example.com --username twsowner
--password <YUNOHOST_ADMIN_PASSWORD_HOME_A> --ignore-dyndns
--force-diskspace --i-have-read-terms-of-services`, adds all six app
subdomains, and installs **self-signed** certs where no cert exists.

**Expected:** ends with
`[tinywebstack] YunoHost bootstrap complete for home.example.com node=home-a (admin: twsowner)`.
Then `https://home.example.com/` loads with a self-signed warning, and the
admin portal works at `https://home.example.com/yunohost.admin` (log in as
`twsowner`).
*If this fails:*
- postinstall DNS errors → §1.2 not satisfied (the domain must resolve to this
  box publicly); `yunohost tools postinstall` logs land in `yunohost log list`.
- "Server is unreachable" behind NAT → the hairpin/`/etc/hosts` trick (§1.3).
- `YUNOHOST_ADMIN_PASSWORD must be set` → you skipped §2.3 secret generation,
  or the node name doesn't match the secret key (`home-a` →
  `YUNOHOST_ADMIN_PASSWORD_HOME_A`).
- Re-running the script is safe: every step is idempotent.

---

## 3. Let's Encrypt (replace bootstrap's self-signed certs)

There is **no production TLS path in the scripts** (they handle lab-CA certs or
self-signed) — this is a manual step, done once per domain, **after** §2.4 and
**before** apps start federating. For each of the six domains, on the node:

```bash
for d in home.example.com matrix.home.example.com element.home.example.com \
         owntracks.home.example.com nextcloud.home.example.com mobilizon.home.example.com; do
  sudo yunohost domain cert install "$d"
done
```

**Expected per domain:** `Success! Successfully installed Let's Encrypt
certificate for domain ...!` (YunoHost uses `acme_ynh`/HTTP-01 on port 80;
renewal is automatic via the `acme_ynh__main` service — check with
`sudo yunohost domain cert status home.example.com`).
*If this fails:*
- `Could not sign the new certificate` / ACME fetch failure → port 80 not
  reachable from the internet (§1.3), or DNS not propagated (§1.2).
- YunoHost's own reachability self-check fails behind NAT → add
  `127.0.0.1 <fqdn>` lines to `/etc/hosts` on the node, or pass `--no-checks`.
- Rate-limited (too many retries): Let's Encrypt throttles repeated failed
  orders per domain — wait ~1 h and retry once DNS/port-forward are truly OK.
- If a cert is corrupt beyond repair: `sudo yunohost domain cert install <d>
  --self-signed --force`, then re-run this step.

Sanity: `echo | openssl s_client -connect home.example.com:443
-servername home.example.com 2>/dev/null | openssl x509 -noout -issuer`
→ `issuer= ... Let's Encrypt ...` for all six names.

---

## 4. Install the family apps

From the control machine:

```bash
scripts/vm/remote-run.sh "$IP" yunohost-family-apps.sh home.example.com home-a
```

Installs (idempotently, via `yunohost app install --args`): Synapse
(`domain=matrix.…`, `server_name=home.example.com`, registration off), Element,
OwnTracks (after `prep-owntracks-apt.sh`; Traccar + `setup-traccar-admin.sh`
if `LOCATION_APP=traccar`), and Nextcloud with the Calendar app enabled.

**Expected:** final line
`Apps on home.example.com: Synapse https://matrix.home.example.com | Element https://element.home.example.com | owntracks https://owntracks.home.example.com`.
Verify: `ssh root@"$IP" yunohost app list` → includes `synapse`, `element`,
`nextcloud`, `owntracks`.
*If this fails:*
- owntracks_ynh apt failures → the script auto-retries after
  `prep-owntracks-apt.sh`; if it still dies, check the node can reach
  `repo.owntracks.org` (GPG key URL is `OWNTRACKS_APT_KEY_URL` in
  `config/defaults.env`) and re-run.
- nextcloud install timeout on slow disks → just re-run the script.
- Mobilizon is **not** installed here — it's part of `family-init.sh` (§5).

---

## 5. Family layer

```bash
scripts/vm/remote-run.sh "$IP" family-init.sh home.example.com
```

**Do not pass the node name here in production.** With `NODE_NAME` the script
additionally runs `create-family-test-users.sh` and `setup-family-calendars.sh`
— lab scaffolding you don't want. Without it,
`family-init.sh` runs: `family-groups.sh` → `install-mobilizon.sh` →
`install-family-module.sh` → `family-permissions-seed.sh` →
`install-family-dashboard.sh` → `family-federation-state-seed.sh` →
`install-tinyweb-portal-branding.sh`.

- `family-groups.sh` creates `parents`, `kids`, `federation-test` groups and
  the permission model (Element/Synapse to family groups only; location web
  to `parents` only; dashboard permission `synapse.family_dashboard` → parents).
- `install-family-module.sh` pip-installs `tinywebstack_family` and
  `tinywebstack_permissions` into the Synapse venv and writes
  `/etc/matrix-synapse/conf.d/tinywebstack-family.yaml`
  (spam-checker module, SQLite `permissions_db`, `reject_encryption: true`,
  E2EE off) + `/etc/tinywebstack/family-policy.json`, then restarts Synapse.
- `family-permissions-seed.sh` creates `/etc/tinywebstack/permissions.db` once
  (roles + one-time import from `family-policy.json` when the DB is empty).
- `family-federation-state-seed.sh` merges existing `trusted_domains` from
  policy and the Synapse allowlist snippet into `federation-state.json`.
- `install-family-dashboard.sh` builds the FastAPI dashboard venv at
  `/opt/tinywebstack-family-dashboard`, systemd unit on 127.0.0.1:8765, nginx
  snippet at `https://home.example.com/family/`, sudoers for the privileged
  helper, and provisions the Synapse admin token.
- The lab-CA hooks degrade cleanly with no lab CA present
  (`mobilizon-lab-ca-trust.sh` logs `No lab CA present — Mobilizon bundled CA
  patch skipped (production or unstaged certs)` and exits 0).

**Expected:** `[tinywebstack] Family layer init complete for home.example.com`,
and `https://home.example.com/family/` → YunoHost SSO login → parents see the
dashboard.
*If this fails:*
- Mobilizon is the slow/heavy one (Elixir migration, ~10 min). If
  `install-mobilizon.sh` dies mid-install, `yunohost app remove mobilizon`
  (only if half-installed) and re-run `family-init.sh`.
- dashboard 502 → `sudo systemctl status tinywebstack-family-dashboard`
  and `journalctl -u tinywebstack-family-dashboard -e` on the node.
- `Missing .../brand/portal` or `family/synapse_module` → someone ran the
  script from a git clone on the node instead of via `remote-run.sh` (§0).

### 5.4 Hardening the TLS flags for production (manual, required)

1. **Dashboard:** `install-family-dashboard.sh` defaults
   `TWS_LAB_TLS_INSECURE=1` in `/etc/tinywebstack/dashboard.env` unless the
   env var was already set (§2.3). Verify and fix on the node:

   ```bash
   ssh root@"$IP" grep TWS_LAB_TLS_INSECURE /etc/tinywebstack/dashboard.env
   # must read: TWS_LAB_TLS_INSECURE=0
   sudo sed -i 's/^TWS_LAB_TLS_INSECURE=1/TWS_LAB_TLS_INSECURE=0/' \
     /etc/tinywebstack/dashboard.env
   sudo systemctl restart tinywebstack-family-dashboard
   ```

   With `=1`, the dashboard's invite peer-verification
   (`family/dashboard/.../peer_verify.py`) and the Synapse calls in
   `family-dashboard-privileged.sh` run with certificate verification **off**.
2. **Remove any stale lab CA on the node** (only exists if the node ever ran
   the lab path): `sudo rm -f /etc/tinywebstack/lab-ca.pem`.
3. **Synapse federation snippet:** if you have already run the federation
   allowlist scripts (§6/§7), `synapse-federation-allowlist.sh` writes
   `federation_verify_certificates: false` whenever no lab CA is staged. That
   is a lab convenience that is **wrong in production** — after linking
   (§6/§7), on each node:

   ```bash
   sudo sed -i '/federation_verify_certificates: false/d; /Lab-only fallback/d' \
     /etc/matrix-synapse/conf.d/tinywebstack-federation.yaml
   sudo systemctl restart synapse
   ```

   Both households federate over public Let's Encrypt certs (system trust), so
   verification must stay on. **Expected after fix:**
   `sudo grep federation_verify /etc/matrix-synapse/conf.d/tinywebstack-federation.yaml`
   prints nothing.

---

## 6. Create real family accounts

Two supported paths; use either or both. `twsowner` (YunoHost admin) stays
separate from family members — parents are **not** Synapse admins so the
spam-checker rules apply to them (plan decision 2).

### 6.1 Dashboard (recommended for non-technical parents)

As a member of `parents` (bootstrap created none — seed the first parent via
§6.2, then everyone else lives here): open
`https://home.example.com/family/` → **Members → Add family member**
(`member_add.html` flow). It calls
`family-dashboard-privileged.sh user-create USER "Full Name" parent|kid DOMAIN`
via passwordless sudo — which runs `yunohost user create USER -F "Full Name"
-p <password> -d DOMAIN`, adds the user to `parents`/`kids`, re-applies
`family-groups.sh`, and activates the Matrix account through the Synapse admin
API (`matrix_reactivated=1` in its output). Also available on the node:
`user-delete`, `password-reset` (kid credential recovery), `list-users`.

### 6.2 CLI seed (YunoHost 12 — `user create` is CLI-only)

```bash
ssh root@"$IP"
sudo yunohost user create mom -F "Mom Example" -p '<password ≥8 chars>' -d home.example.com
sudo yunohost user group add parents mom
# kids:
sudo yunohost user create kid1 -F "Kid One" -p '<password>' -d home.example.com
sudo yunohost user group add kids kid1
```

Note: `-F` full-name flag only — `--firstname`/`--lastname` do not exist on
YunoHost 12 (known lab-doc pitfall; the scripts use the same `-F -p -d` form).
Then sync the new accounts into Matrix/Nextcloud groups:

```bash
scripts/vm/remote-run.sh "$IP" family-groups.sh
```

**Expected:** `yunohost user list` shows the users in `parents`/`kids`;
Element at `https://element.home.example.com` (or Element X pointed at the
main domain) logs in with the YunoHost SSO; portal at `https://home.example.com/`
shows each user only their permitted apps.
*If this fails:*
- password rejected → 8-char minimum, and YunoHost's zxcvbn policy may
  reject obvious ones;
- user can't see Element → permission drift: re-run `family-groups.sh`
  (idempotent) and check `yunohost user permission list | grep -A3 element.main`.

Calendars: run `setup-family-calendars.sh` for the shared family calendar +
personal calendars. Pass your real members with `--users` and set explicit
roles: `TWS_FAMILY_PARENTS` / `TWS_FAMILY_KIDS` (required whenever the list
is not the lab default `parent,kid`). The calendar owner is the first user
unless `TWS_FAMILY_OWNER` overrides. Example on the node:

```bash
ssh root@"$IP"
cd /opt/tinywebstack && TW_STACK_ROOT=/opt/tinywebstack \
TWS_FAMILY_USERS='william,sophie,emma' \
TWS_FAMILY_PARENTS='william,sophie' \
TWS_FAMILY_KIDS='emma' \
WILLIAM_PASSWORD='<william password>' \
bash vm/setup-family-calendars.sh home.example.com home-a --users 'william,sophie,emma'
```

Phones then point CalDAV at `https://nextcloud.home.example.com/nextcloud/remote.php/dav`
with the YunoHost username + the user's Nextcloud app password (dashboard
CalDAV page shows per-user setup). *If verify later fails with 401:* Nextcloud
LDAP group sync lag — `sudo -u www-data php /var/www/nextcloud/occ
ldap:check-group <group> --update`.

---

## 7. Link the second household

Preferred: **dashboard invite flow** ([FAMILY_INVITE.md](FAMILY_INVITE.md)) —
Parent A: *Link another household → Generate invite*; Parent B: *Redeem
invite*. Mutual Synapse signing-key verification runs over public HTTPS
(needs §5.4 done, or it will "verify" nothing), both nodes update
`/etc/tinywebstack/family-policy.json` `trusted_domains`, and
`family-sync-federation.sh` regenerates the Synapse federation allowlist +
Mobilizon relays on each side.

Alternative (both nodes are yours, script-driven) — from the control machine,
with both rows in `config/nodes.conf` (§2.3):

```bash
scripts/spark/configure-federation-pair.sh "root@<ip-a>" "root@<ip-b>"
```

Despite living in `scripts/spark/`, this only uses `remote-run.sh` +
`nodes.conf` domains — no lab-CA or `ssh-spark` dependency — but see §5.4
step 3: it leaves `federation_verify_certificates: false` in the Synapse
snippet until you strip it.

**Expected:** on each node,
`/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml` contains the peer's
domain under `federation_domain_whitelist`, and Mobilizon's trusted-instance
list matches (Mobilizon sync output: JSON with no `"errors"`).
*If this fails:* federation `M_FORBIDDEN` even though allowlisted → peer DNS
or cert problem on the *other* side (`curl -s
https://matrix.home.b.example/_matrix/key/v2/server` must return JSON with a
`verify_key`); Mobilizon sync `Bad credentials` → the admin user is
`twsowner@home.example.com` and the password is
`YUNOHOST_ADMIN_PASSWORD_HOME_A` from the secrets file (or set
`MOBILIZON_ADMIN_PASSWORD`).

`ip_range_whitelist` in the snippet is lab-scoped (`192.168.122.0/24` default).
On production nodes with public IPs, **delete the `ip_range_whitelist` block**
from `/etc/matrix-synapse/conf.d/tinywebstack-federation.yaml` and restart
Synapse — do **not** set `FEDERATION_IP_RANGE_WHITELIST=0.0.0.0/0` (that
disables Synapse SSRF protection). Public federation does not require an open
IP range when homes federate over HTTPS on the public Internet.

---

## 8. Verification

The three e2e verifiers live in `scripts/spark/`. They prefer the lab CA when
present (`TW_STACK_LAB_CA_DIR` / `TWS_CA_BUNDLE`) but fall back to the system
trust store when it is absent (`TWS_REQUIRE_LAB_CA=1` restores the old
hard-fail). Participant usernames and passwords come from env or the secrets
file (`TWS_FAMILY_USERS`, `TWS_ALICE_USER`, etc.). Two options:

**Option A — reuse the verifiers (they are not spark-coupled; they hit
public HTTPS APIs and read the local secrets file).** On the control machine:

```bash
# Point the lab-CA resolver at the system trust store instead of the lab CA:
mkdir -p ~/.tinywebstack-secrets/prod-ca
ln -sf /etc/ssl/certs/ca-certificates.crt ~/.tinywebstack-secrets/prod-ca/lab-ca.crt.pem
export TW_STACK_LAB_CA_DIR=~/.tinywebstack-secrets/prod-ca

scripts/spark/verify-federation-e2e.sh home-a home-b \
  home.example.com home.b.example <userA> <userB> matrix.org
scripts/spark/verify-calendar-e2e.sh home-a home.example.com     # needs parent/kid users
scripts/spark/verify-events-e2e.sh   home-a home-b \
  home.example.com home.b.example mobilizon.fr
```

Works only with users that exist and passwords in `passwords.env` (the lab
`alice`/`bob`/`parent`/`kid` pattern). **Expected:** federation: room created
on A, joined by B, message visible via `/messages`, and `M_FORBIDDEN` for the
`matrix.org` rejection probe; calendar: CalDAV login + invite round-trip;
events: nodeinfo public, trusted-instance sync, cross-family RSVP,
`mobilizon.fr` not followed.

**Option B — manual checks mirroring the assertions** (no users to spare):

| Check | Command / action | Expected |
|-------|------------------|----------|
| Matrix well-known | `curl -s https://home.example.com/.well-known/matrix/server` | JSON pointing at `matrix.home.example.com` |
| Federation works | A-user DMs `@<b-user>:home.b.example` from Element X | message delivered both ways |
| Federation restricted | try to join `#matrix.org:matrix.org` (or invite from a stranger's server) | refused (`M_FORBIDDEN` / never syncs) |
| E2EE off | create a family room | no encryption shield; module rejects enabling encryption |
| Kid policy | kid (in `kids`) tries a room invite outside the allowlist | blocked by `tinywebstack_family` module |
| Dashboard | kid logs in at `/family/` | 403/SSO-denied (parents perm only); parent sees home |
| Location | kid's OwnTracks app publishes to `https://owntracks.home.example.com/recorder/pub` (htpasswd issued by dashboard) | parent sees the trace on the map; kid does **not** get the web UI |
| CalDAV | `curl -u kid1 -X PROPFIND https://nextcloud.home.example.com/nextcloud/remote.php/dav/principals/users/kid1/` | `207`, calendar homes listed |
| Mobilizon portal | `curl -sI https://mobilizon.home.example.com/.well-known/nodeinfo` | `200` JSON, no SSO redirect |
| Cert hygiene | §5.4 greps | no `federation_verify_certificates: false`, `TWS_LAB_TLS_INSECURE=0` |

---

## 9. Backups, updates, upgrades

### Backups (nothing in the repo — fully manual today)

On the node:

```bash
sudo yunohost backup create --apps synapse,element,nextcloud,mobilizon,owntracks --output /backups
# plus system config:
sudo tar czf /backups/etc-tinywebstack-$(date +%F).tgz /etc/tinywebstack \
  /etc/matrix-synapse/conf.d /etc/nginx/conf.d
```

Copy off-box (the dashboard's own files, `/opt/tinywebstack`,
`/opt/tinywebstack-family-dashboard`, `/etc/tinywebstack/family-policy.json`,
`dashboard.env`, `pending-invites.json`, `synapse-admin-token`, and the
control machine's `~/.tinywebstack-secrets/passwords.env` are **not** inside
app archives beyond YunoHost's `system` archive — include `--apps system` or
the tar above). Restore: `yunohost backup restore <archive>`, then re-run §5
(the scripts are idempotent) to rebuild the module/dashboard.

Test restore quarterly; an untested backup is not a backup.

### Updates

- Routine: `sudo apt update && sudo apt upgrade`, `sudo yunohost apps
  upgrade`, `sudo yunohost tools upgrade` from a **backup you just took** —
  each via admin panel or CLI, one app at a time, checking `yunohost app
  list --full` status after each.
- **After every `yunohost app upgrade synapse`:** the app upgrade recreates
  the Synapse venv and drops the pip-installed `tinywebstack_family`. Run
  `scripts/vm/remote-run.sh "$IP" family-module-post-upgrade.sh
  home.example.com` — it checks the venv, and if the module was wiped it
  re-applies `install-family-module.sh` (pip package, conf.d snippet,
  Synapse restart); if the module is healthy it is a no-op, so it is safe to
  run anytime. **Expected:** Synapse starts and `[tinywebstack] Synapse
  family module re-applied` (or `nothing to do`). If you skip this, kid
  spam-checker rules silently stop applying while everything else looks
  fine. See [module-packaging.md](module-packaging.md) (S5.4) for the
  optional weekly-cron variant.
- Similarly after `yunohost app upgrade owntracks`: the `/recorder/pub` nginx
  snippet is drop-in under `conf.d/owntracks.home.example.com.d/` and
  survives, but verify with the location row in §8's table.
- After `yunohost app upgrade mobilizon`: `mobilizon-lab-ca-trust.sh` is a
  no-op in production; nothing to do unless federation errors appear, then
  re-run `mobilizon-federation-sync.sh` via `remote-run.sh`
  (`<MAIN_DOMAIN> <NODE> [peer-domain]`).
- Keep the control-machine checkout current (`git pull`); deploy changes by
  re-running the relevant `remote-run.sh` (rsync-based, idempotent).

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `remote-run.sh`: `Host key verification failed` / BatchMode prompt | host key not pinned, or password auth | `ssh-keyscan <ip> >> ~/.tinywebstack-secrets/known_hosts`; §2.2 key auth |
| `remote-run.sh`: `Invalid node name ... (looks like a domain)` | passed FQDN where the node **id** belongs | `remote-run.sh <ip> install-family-dashboard.sh home.example.com home-a` (id last) |
| `Missing /opt/tinywebstack/family/... (sync family/ to the node)` | script run from a git clone on the node | always drive via `remote-run.sh` (§0) |
| postinstall fails "domain not reachable" | DNS/port-forward/hairpin | §1.2, §1.3; `/etc/hosts` loopback entries |
| Let's Encrypt install fails for one subdomain | that name's DNS or port 80 | §1.2 per-name `dig`; router forward covers all names on one IP |
| Dashboard 502 at `/family/` | systemd unit down | `journalctl -u tinywebstack-family-dashboard -e`; re-run `install-family-dashboard.sh` |
| Dashboard login loops / 403 for parent | perm drift | `scripts/vm/remote-run.sh <ip> family-groups.sh`; check `TWS_DASHBOARD_PERM` in `/etc/tinywebstack/dashboard.env` |
| Element: `Unable to connect to homeserver` | matrix well-known or cert | `curl -s https://home.example.com/.well-known/matrix/server`; §3 |
| Cross-household DM silently fails | federation allowlist missing, snippet's `ip_range_whitelist` left at lab `192.168.122.0/24`, or cert verification issue | §7 (both fixes), `journalctl -u synapse -e` on both nodes |
| Mobilizon sync `Bad credentials` | admin email/password mismatch | admin is `${YUNOHOST_ADMIN_USER}@<main>` with `YUNOHOST_ADMIN_PASSWORD_<NODE>`; or export `MOBILIZON_ADMIN_PASSWORD` |
| Kid sees the location web UI | `family-groups.sh` not re-run after manual app install | re-run it; check `yunohost user permission list` |
| OwnTracks app gets 401 on publish | kid htpasswd not issued | dashboard OwnTracks page (uses `family-dashboard-privileged.sh owntracks-issue`), or issue via SSH |
| Password too short errors | YunoHost ≥8-char policy | regenerate that key in `passwords.env` (delete key, re-run `ensure-node-secrets.sh`) |
| `sudo yunohost domain cert renew` says "not issued by Let's Encrypt" | domain still on self-signed | you skipped §3 for that name |
| Everything fine but federation dropped after cert expiry | LE renewal failed silently | `sudo yunohost domain cert status`; renew manually (`yunohost domain cert renew <d>`) |

---

## Known gaps for v1.1

1. **No production TLS path in the scripts.** `yunohost-bootstrap.sh` only
   knows lab certs and `--self-signed`; Let's Encrypt is a manual per-domain
   loop (§3). Needs a `--production` flag that runs
   `yunohost domain cert install` for every node domain.
2. **`synapse-federation-allowlist.sh` silently disables federation TLS**
   (`federation_verify_certificates: false`) whenever the lab CA isn't staged
   — correct in lab, a security regression in production (§5.4.3). Should
   default to verified and take an explicit `--insecure-federation` lab flag.
3. **`mobilizon-federation-sync.sh` uses an unverified TLS context whenever
   `/etc/tinywebstack/lab-ca.pem` is absent** — which is exactly the
   production case; it should fall back to the system trust store
   (`ssl.create_default_context()`), not to no verification. Same class of
   issue: `install-family-dashboard.sh` writes `TWS_LAB_TLS_INSECURE=1` by
   default into `dashboard.env`, and `peer_verify.py` honours it (§5.4.1).
4. **Member provisioning is script-driven but explicit.** Custom households
   must set `TWS_FAMILY_PARENTS` and `TWS_FAMILY_KIDS` alongside
   `TWS_FAMILY_USERS` (§6.2). `family-init.sh`'s NODE_NAME-gated block is still
   lab scaffolding glued onto the production orchestrator.
5. **`yunohost-bootstrap.sh` passes `--ignore-dyndns` unconditionally** — no
   DynDNS support for residential ISPs (§1.3).
6. **Verifiers are lab-CA-coupled:** `verify-federation-e2e.sh` and
   `verify-events-e2e.sh` hard-fail without a `lab-ca.crt.pem` (the
   `TW_STACK_LAB_CA_DIR` symlink-to-system-bundle trick in §8 Option A is a
   workaround, not a feature), and all three assume `alice`/`bob`/`parent`/
   `kid` secret keys. Needs a `--production` mode (system CA, configurable
   users).
7. **`remote-run.sh` requires root-over-SSH** (BatchMode, no sudo-password
   path); production Debian needs manual root key install (§2.2). Also its
   "spark"/`TW_STACK_SECRETS_SOURCE=spark` naming leaks lab vocabulary.
8. **Synapse module is a pip wheel install into the app venv** (S5.4 done —
   see [module-packaging.md](module-packaging.md)) —
   `yunohost app upgrade synapse` still wipes the venv, but the wipe is now
   detected and repaired by one command:
   `scripts/vm/remote-run.sh "$IP" family-module-post-upgrade.sh
   <MAIN_DOMAIN>` (§9). No YunoHost post-upgrade hook exists; the manual
   command (or the documented weekly-cron variant) closes the silent-stop
   gap.
9. **No backup tooling in the repo:** `/etc/tinywebstack`, `/opt/tinywebstack*`
   and the control machine's `passwords.env` fall outside `yunohost backup
   --apps`; only a manual tar covers them (§9). Needs a
   `scripts/vm/backup-family-state.sh`.
10. **`configure-federation-pair.sh` handles only the first two rows of
    `nodes.conf`** and its RAM/VCPU/DISK columns are meaningless on real
    hardware — needs a proper production node registry.

## Related documents

- [FAMILY_LAYER_PLAN.md](FAMILY_LAYER_PLAN.md) — feature plan (this doc = S5.2)
- [test-nodes.md](test-nodes.md) — lab path (spark VMs, private CA)
- [FAMILY_DASHBOARD.md](FAMILY_DASHBOARD.md), [FAMILY_MODULE.md](FAMILY_MODULE.md),
  [module-packaging.md](module-packaging.md),
  [CALENDAR.md](CALENDAR.md), [EVENTS.md](EVENTS.md),
  [FAMILY_INVITE.md](FAMILY_INVITE.md), [TINYWEB_BRANDING.md](TINYWEB_BRANDING.md),
  [PHILOSOPHY.md](PHILOSOPHY.md)
