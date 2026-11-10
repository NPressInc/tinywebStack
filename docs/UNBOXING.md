# Unboxing

Customer setup for a TinyWeb box. Product priority and workstream order live in [PLAN.md](../PLAN.md). This file is the spec a later change can implement against.

Operators still use [production-setup.md](production-setup.md). Do not send a parent through that runbook.

## What the parent does

1. Plug in power and ethernet. The phone is on the same home Wi-Fi. The box does not join Wi-Fi itself in v1.
2. Open the TinyWeb app. If it is not installed, the setup QR's https link is what should reach the App Store or Play Store. Listing text is in the repo; the app is not submitted, and the https page is not hosted yet.
3. The phone finds the box on the LAN. The parent scans the setup QR, or types the code.
4. The parent types the family name, their name, and a password they choose.
5. The app stays on a progress screen while the box becomes `<family>.tinyweb.win`, gets a real Let's Encrypt certificate, and finishes install.
6. The parent adds everyone else with the existing one-link QR at `https://<family>.tinyweb.win/family/join#code=…`.

The parent does not see a terminal, a router admin page, YunoHost, or a certificate warning. TinyWeb does not use ads.

## Setup QR

Printed twice: a card in the lid, and a sticker on the bottom. Both carry the same code.

The QR is only a pairing code for that physical unit:

- `https://tinyweb.win/setup#code=<token>` (this is the printed form)
- `tinyweb://setup#code=<token>` (same token, for a phone that already has the app)

The token is the secret. It sits in the URL **fragment**, so a request to tinyweb.win does not include it and an access log must not contain it. The app reads the fragment locally and sends the token only to the box on the LAN. It does not fetch the https URL to "redeem" the code.

The QR must not contain the parent password, a session token, or a Matrix recovery key.

The token is one-time **after provisioning succeeds**, not after a scan. A failed or unfinished setup keeps the same QR. After the family is set up, that QR cannot take over or reclaim the box. Reclaiming needs the parent (not built).

The phone sends the token only to the box on the LAN. The box then sends it in a JSON body to the control plane (`POST /v1/setup/claim`) when it reserves `<family>.tinyweb.win`. It is not placed in a query string, and the phone does not POST the fragment to tinyweb.win.

On success the setup service deletes `/etc/tinywebstack/setup-code` and writes `/etc/tinywebstack/setup-code.consumed` with a timestamp only. On failure it leaves the code in place.

## Recovery key

The parent chooses the first password in the app. The Matrix recovery key is created on the first phone after setup, shown once in the app (the existing secure-chats screen), and should be saved. The box ships with a **blank** card for that key. The card is packaging. It is not a factory-printed secret.

## Workstreams

### A. Pre-imaged box and LAN wizard — started

Software in this repo:

- `scripts/setup/tinyweb-setupd.py` listens only while the box is unprovisioned, and only on a private LAN address (or loopback when `TWS_SETUP_BIND` is loopback, for tests). It refuses a public bind.
- It answers mDNS for `_tinyweb-setup._tcp.local` and broadcasts a small UDP beacon on port `4735`. Neither carries the setup code or a password.
- `GET /v1/setup/status` and `POST /v1/setup` on port `4734` (HTTP, LAN only).
- The Flutter first-run screen (`app/lib/src/setup/`) searches the LAN, accepts a scanned or typed setup code, collects the family and the first parent, and polls progress. "Join a family that is already set up" opens the existing enroll screen. An enroll link still enrolls against an already-provisioned server.

The POST body is `{ "code", "family_name", "parent_name", "password" }`. `code` may be the raw token or either setup link above. A `code` query parameter is rejected so the secret is not placed where servers log URLs.

The service writes `/etc/tinywebstack/tinyweb.env` (no password) and pre-seeds `<USER>_PASSWORD` in `/etc/tinywebstack/secrets/install.env` (mode `600`) so `scripts/install-on-box.sh` keeps that password. Display name is `TWS_FAMILY_OWNER_FULLNAME`. It does not log the password or the setup code.

Progress steps, in order: name the family, install, reserve `<family>.tinyweb.win`, Let's Encrypt certificate, internet path, ready. Install is the existing one-box installer. The name, certificate, and tunnel steps stay blocked until the control plane has published DNS, the edge certificate is ready, and the tunnel apply succeeds. The API does not report them done, and it does not report `ready`, while any of those is missing.

Shippable disk image (design only):

- Debian 12 base that can run the one-box installer, with this setup unit enabled.
- Ethernet DHCP. No Wi-Fi client and no access point in v1.
- `/etc/tinywebstack/setup-code` installed before first boot.
- systemd unit `scripts/setup/tinyweb-setupd.service` (`ConditionPathExists=!/etc/tinywebstack/unboxing-complete`).
- After a successful unboxing the marker `/etc/tinywebstack/unboxing-complete` exists and the unit does not listen. A box that already has `/etc/yunohost/installed` and no in-progress setup state does not listen either, so an operator install is left alone.

Wi-Fi-only first boot for the box is a later image change.

### Before the box ships

The Debian image and the flashing step are not in this repo. On a box that already has this tree (a git checkout, or the flat `/opt/tinywebstack` copy the installer uses), William runs:

```bash
sudo TWS_CONTROL_PLANE_URL=https://tinyweb.win \
  TWS_CONTROL_PLANE_OPERATOR_TOKEN='…' \
  python3 scripts/setup/pre-ship.py
```

From the flat image path, that is `python3 /opt/tinywebstack/setup/pre-ship.py`.

The script:

- Calls `POST /v1/operator/units` and receives the setup code once.
- Writes `/etc/tinywebstack/setup-code` (mode `600`, one line, URL-safe, at least 128 bits).
- Writes `/etc/tinywebstack/setup-qr.svg` (mode `600`) for the lid card and the bottom sticker. Both print the same `https://tinyweb.win/setup#code=<token>`. Stdout also prints that URL and `tinyweb://setup#code=<token>`. Stdout is the print surface. The token is not written to a log file, and the operator token is read from the environment, not the command line.
- Enables `tinyweb-setupd.service` for the next boot and does not start it in the factory. The unit calls the same control plane URL this script used (`https://tinyweb.win` unless `--url` says otherwise).
- Does not set the family name or the parent password. The parent does that in the app.
- Does not print a Matrix recovery key. The box still ships with a blank card for that key.

If the control plane is unreachable or `TWS_CONTROL_PLANE_OPERATOR_TOKEN` is missing, the script exits with an error and does not invent a code. `--dry-run` checks that the token is set and does not call the network. Tests point `--url` at the control plane's fake provider.

Copy the SVG off the box, print two copies, and do not leave the SVG on a shared printer. The setup-code file stays on the box. Then power the box off.

### B. Control plane

William's service at tinyweb.win (`controlplane/`) reserves the family slug, publishes DNS for `<family>.tinyweb.win` and the service hosts, and orders one real edge certificate (Advanced Certificate Manager by default, Let's Encrypt). See [CONTROL_PLANE.md](CONTROL_PLANE.md).

The box presents its setup token when it claims the name. The control plane does not see family chat, calendars, files, or location. It only coordinates names, certificates, and tunnel credentials.

During setup the box calls, in order: `GET /v1/slugs/{slug}`, `POST /v1/setup/claim`, `POST /v1/tunnels`, `scripts/cloudflared-apply.sh`, and, only when DNS is published and the edge certificate is ready, `POST /v1/setup/complete`. The installer sets `TWS_TLS_SINGLE_SAN_CERT=1` and `TWS_TLS_EDGE_CERT=1`. The edge flag skips on-box Let's Encrypt, because the box does not open port 80. The certificate the phone sees is the edge certificate. The name, certificate, and tunnel steps stay blocked when the control plane is missing, Cloudflare credentials are missing, or the handoff says DNS was not published. The API does not report those steps done, and it does not report `ready`, in that case.

`TWS_SETUP_ALLOW_GATE_OVERRIDE=1` is a test switch for a box that is not talking to the control plane. Do not set it on an image. When `TWS_CONTROL_PLANE_URL` is set, the control plane's answer wins.

### C. Tunnel

Many home ISPs use CGNAT. The parent must not open ports 80 or 443.

v1 default: a per-box Cloudflare Tunnel. The control plane issues the tunnel credentials. It does not forward family traffic through itself. Phone ↔ Cloudflare edge ↔ box.

`scripts/cloudflared-apply.sh` refuses to start `cloudflared` when the token is missing or `published` is not true. It does not refuse because a Jellyfin hostname is present. When `TWS_JELLYFIN=1`, first boot includes `jellyfin.<family>.tinyweb.win` on the tunnel. When Jellyfin is off, that host is not added. Immich is out of scope for v1. The tunnel step stays blocked until apply succeeds for a published handoff.

### D. Stores

Store listing text, privacy drafts, and local build scripts are in the repo. Nothing is uploaded to the App Store or Play Store. See [APP_STORES.md](APP_STORES.md).

The site behavior for `https://tinyweb.win/setup` is still not hosted:

- App installed: the link opens TinyWeb and the fragment fills the setup code. Android declares the `tinyweb://setup` scheme and `https://tinyweb.win/setup`. iOS opens `tinyweb://setup` from the existing `tinyweb` scheme. Associated domains / Digital Asset Links for the https host are not hosted yet, so a scan of the https QR may still open a browser.
- App not installed: the page (not in this repo) reads the fragment in the browser, sends the phone to the right store, and does not POST the fragment to tinyweb.win. The fragment will not survive a store install; the parent scans the card again or types the code.

### E. Push credentials

TinyWeb's own APNs and FCM keys, the same on every box. A family does not upload a `.p8` or a service-account JSON. See [PUSH.md](PUSH.md). The keys are not in git. Until William places them on the box, production push install stops and a lab box keeps a Sygnal stub that refuses delivery.

## API

| | |
| --- | --- |
| Bind | Private IPv4, or link-local. Loopback only if `TWS_SETUP_BIND` is loopback. Never a public address. |
| Peer | Same rule. Other peers get `403`. |
| `GET /v1/setup/status` | Phase, steps, `code_required`, family slug, domain, parent username. No password, no setup code. |
| `POST /v1/setup` | Starts or retries install. `401` wrong code. `409` already in progress or already set up. `429` too many tries. |

Phases: `waiting`, `installing`, `blocked`, `failed`, `ready`.

`ready` and `enroll_origin` (`https://<family>.tinyweb.win`) are set only when the installer exits 0 **and** the control plane has published DNS, the edge certificate is ready, and `cloudflared-apply.sh` succeeded. The app then enrolls with the existing password enrollment and shows the usual "you're all set" checklist, including chat recovery when Matrix enrollment succeeded. From there the parent uses Family controls to add people (existing QR).

While blocked, the app explains the unfinished step in plain language and does not sign the parent in.

## Run the service

On a fresh box, as root, with a setup code file in place:

```bash
sudo install -d -m 700 /etc/tinywebstack
sudo install -m 600 /path/to/setup-code /etc/tinywebstack/setup-code
sudo install -m 644 scripts/setup/tinyweb-setupd.service /etc/systemd/system/tinyweb-setupd.service
sudo systemctl enable --now tinyweb-setupd.service
```

The unit expects the flat deploy tree (`/opt/tinywebstack/setup/tinyweb-setupd.py`), which is where `scripts/` lands after the image or `install-tinyweb.sh` copies it. From a git checkout:

```bash
sudo python3 scripts/setup/tinyweb-setupd.py
```

Useful environment (none of these are the parent password):

| Variable | Role |
| --- | --- |
| `TWS_SETUP_BIND` | Comma-separated bind addresses. Public addresses abort startup. |
| `TWS_SETUP_PORT` | HTTP port, default `4734`. |
| `TWS_ETC_DIR` | Default `/etc/tinywebstack`. |
| `TWS_SETUP_STATE_DIR` | Default `/var/lib/tinywebstack`. |
| `TWS_SETUP_CODE_FILE` | Default `$TWS_ETC_DIR/setup-code`. |
| `TWS_SETUP_ANNOUNCE` | `0` skips mDNS and the beacon. |
| `TWS_SETUP_INSTALL_CMD` | Replacement for `install-on-box.sh` (tests). The family slug is appended. |
| `TWS_YUNOHOST_INSTALLED_FILE` | Default `/etc/yunohost/installed`. If this file exists and setup is not in progress, the service does not listen. |
| `TWS_CONTROL_PLANE_URL` | Control plane base URL. The setup unit sets `https://tinyweb.win`. Empty means the name and tunnel stay blocked. |
| `TWS_SETUP_CLOUDFLARED_DEST` | Stage `cloudflared-apply.sh` here instead of installing the system unit. Tests only. |

## Tests

```bash
python3 -m pytest scripts/tests/test_tinyweb_setupd.py family/calendar_module/tests/test_family_user_args.py -q
```

App (from `app/`):

```bash
flutter analyze
flutter test test/setup_link_test.dart test/unbox_screen_test.dart test/enroll_screen_test.dart test/enroll_link_test.dart test/app_session_test.dart
```

## Not built here

A disk image and a flasher. Wi-Fi setup for the box itself. The public `https://tinyweb.win/setup` page. Submitting the app to a store. Reclaim-by-parent. Do not mark the name, certificate, or tunnel done unless the control plane published them.
