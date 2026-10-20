# Phone testing against the lab (spark + Tailscale)

Use this flow to run the TinyWeb Flutter app on a physical phone against a libvirt family VM on spark, with a **private lab CA** (TLS verification stays enabled).

## Prerequisites

- spark host with Tailscale, libvirt VM (default lab IP `192.168.122.18`, override with `TW_VM_IP`)
- Lab CA public cert: `~/.tinywebstack-secrets/lab-ca/lab-ca.crt.pem`
- Android: arm64 device; iOS: Mac with Xcode for release builds

## Network on spark (`phone-access.sh`)

On spark (requires root, idempotent):

```bash
sudo TW_VM_IP=192.168.122.18 ./scripts/spark/phone-access.sh --up
# tear down:
sudo ./scripts/spark/phone-access.sh --down
```

This script:

1. Runs **dnsmasq** bound only to the host Tailscale IPv4 (`tailscale ip -4`), config in `/etc/tinywebstack-phone/dnsmasq.conf`, systemd unit `tws-phone-dns.service`. It answers `family-b.family.test` (override with `TW_PHONE_LAB_NODE` / `TW_PHONE_LAB_DOMAIN`) with the Tailscale IP.
2. Installs **DNAT** on `tailscale0` for TCP 80 and 443 to the VM, FORWARD accept, and MASQUERADE to `virbr0` via oneshot `tws-phone-nat.service` (rules inserted at high priority so libvirt FORWARD rules do not block).

### Tailscale DNS (split DNS)

In the [Tailscale admin console](https://login.tailscale.com/admin/dns):

1. **DNS** → **Nameservers** → **Add nameserver** → **Custom**
2. Enter spark’s **Tailscale IPv4** (same as `tailscale ip -4` on spark)
3. Restrict to domain **`family.test`** (split DNS only; do not make this the global resolver)

Phones on Tailscale will resolve `*.family.test` via spark; HTTPS to that name hits spark’s Tailscale IP and is forwarded to the VM.

## Trust the lab CA on the device

The app adds the lab CA at **build time** (`TW_LAB_CA_PEM_B64`); you should still install the CA on the OS so other tools and WebViews behave consistently.

### Android

1. Copy `lab-ca.crt.pem` to the phone (e.g. `adb push`).
2. **Settings** → **Security** → **Encryption & credentials** → **Install a certificate** → **CA certificate**
3. Confirm and select the PEM file.

Debug builds also use `network_security_config` (system + user CAs). Release builds rely on the dart-define embedded trust for Dart/Rust HTTP.

### iOS

1. AirDrop or email the `.crt.pem` / use Apple Configurator to install a `.mobileconfig` that includes the CA.
2. **Settings** → **General** → **About** → **Certificate Trust Settings** → enable full trust for the lab CA.

## Build and install

### Android (on spark)

```bash
./scripts/spark/build-lab-apk.sh
# APK: ~/tinyweb-phone/tinyweb-lab.apk
adb install -r ~/tinyweb-phone/tinyweb-lab.apk
```

The script reads `TW_LAB_CA_FILE` (default `~/.tinywebstack-secrets/lab-ca/lab-ca.crt.pem`), base64-encodes it into `TW_LAB_CA_PEM_B64`, and builds release arm64 when possible; on linux-arm64 without `gen_snapshot` it falls back to debug.

### iPhone (on Mac)

```bash
cd app
flutter run --release \
  --dart-define=TW_LAB_CA_PEM_B64=$(base64 < /path/to/lab-ca.crt.pem | tr -d '\n')
```

Enroll against `https://family-b.family.test` (or your lab node name) once DNS and CA trust are in place.

## Test accounts

Use the lab **parent** and **kid** accounts from your secrets store (same as `lab_test/` on spark: `TW_TEST_PASSWORD`, optional `TW_PARENT_USER` / `TW_KID_USER`).

## Related

- App lab TLS: [app/README.md](../app/README.md#lab-tls)
- Lab certs on spark: `scripts/spark/stage-lab-certs.sh`
