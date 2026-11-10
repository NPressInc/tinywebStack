# Control plane and Cloudflare Tunnel

TinyWeb home boxes get a public name without the parent opening a router page, creating a Cloudflare account, or clicking through a certificate warning. The service in `controlplane/` is that control plane. It runs for the operator of `tinyweb.win`. It is not a place family traffic goes.

Chat, calendars, files, and location stay on the path below. They do not hairpin through the control-plane host.

1. The box opens an outbound `cloudflared` connection to Cloudflare.
2. DNS for `<family>.tinyweb.win` and the service hosts are proxied `CNAME` records pointing at `<tunnel-id>.cfargotunnel.com`.
3. Cloudflare presents the edge certificate and forwards the request down that already-open tunnel to `https://127.0.0.1:443` on the box.
4. The phone validates Cloudflare's certificate. The origin hop uses `noTLSVerify` because it connects to `127.0.0.1`, which will not match the public name.

v1 assumes the box is on ethernet and the parent's phone is on the same home Wi-Fi for the first setup. This service does not discover the box on the LAN. The phone talks to the box's local setup API (separate work). The box calls this API over HTTPS.

Do not deploy this service from this repository's tests. Unit tests never need Cloudflare credentials.

## What this service does

- Check whether a family slug is free, then reserve it.
- Accept the one-time factory setup code until setup is marked complete.
- Create one remotely managed Cloudflare Tunnel per box and hand the box its token.
- Publish proxied `CNAME` records for the family name and the service hosts from [`scripts/lib/domains.sh`](../scripts/lib/domains.sh).
- Order an edge certificate that covers nested names such as `matrix.smith.tinyweb.win`.
- Revoke that tunnel. Revoke does not free the family name, and it does not make the factory QR work again.

There is no route that proxies Matrix, calendars, files, or location. `GET /v1/health` reports which provider is configured. It does not claim that a family name resolves.

## Factory setup code

The lid card and the bottom sticker carry one code. The secret is in the URL fragment, so a server access log does not see it:

- `https://tinyweb.win/setup#code=<setup-code>`
- `tinyweb://setup#code=<setup-code>`

This service does not serve the setup page. The page and the app (separate work) read the fragment and give the code to the box. The box posts the code in a JSON body. Query strings are rejected.

The code keeps working until the box calls `POST /v1/setup/complete`. Repeating the claim with the same code and the same slug returns the same claim token, so a lost response can be retried. A different slug is refused once a name is reserved. After complete, the code cannot take over the box. Reclaiming uses the claim token the box stored, and the box should only do that after the parent authenticates locally. This service never receives the parent password. The parent chooses that password in the app.

## API the pairing flow calls

Base URL is the operator's control plane (`https://tinyweb.win` once it is placed there). Requests and responses are JSON. Send `Authorization: Bearer <token>` where a token is required.

| Step | Call | Who |
| --- | --- | --- |
| Mint a unit and the sticker secret | `POST /v1/operator/units` | Operator |
| Check a name while the parent types | `GET /v1/slugs/{slug}` | Box |
| Reserve the name and consume the setup code | `POST /v1/setup/claim` | Box |
| Fetch tunnel credentials | `POST /v1/tunnels` | Box, with the claim token |
| Install `cloudflared` | [`scripts/cloudflared-apply.sh`](../scripts/cloudflared-apply.sh) | Box |
| Parent sets a password locally | not this API | App |
| Mark setup finished | `POST /v1/setup/complete` | Box, with the claim token |
| Later status, without secrets | `GET /v1/families/{slug}` | Box or operator |
| Revoke the tunnel | `POST /v1/tunnels/revoke` | Box (claim token) or operator |

`POST /v1/setup/claim`

```json
{ "setup_code": "<from the fragment>", "slug": "smith" }
```

`200` the first time and on a retry before complete:

```json
{
  "status": "claimed",
  "replayed": false,
  "unit_id": "unit…",
  "slug": "smith",
  "domain": "smith.tinyweb.win",
  "claim_token": "<store this on the box>"
}
```

| Status | `error` | Meaning |
| --- | --- | --- |
| 401 | `unknown_setup_code` | The code is not a minted unit. |
| 409 | `slug_taken` | Another box already reserved that name. |
| 409 | `slug_already_reserved` | This code is already reserving a different name. `slug` says which. |
| 409 | `setup_already_complete` | Setup finished. The code cannot take over the box. |
| 400 | `invalid_slug` or `reserved_slug` | Not a single DNS label, or a reserved label such as `www`. |
| 400 | `secret_in_query` | A secret was put in the query string. |

Slugs are one label, matching `scripts/lib/tinyweb-install-env.sh`: letters, digits, and hyphens, stored lowercase. `Smith` is `smith.tinyweb.win`.

`POST /v1/tunnels` with `Authorization: Bearer <claim_token>`. The body may be `{}`. Optional fields: `location_app` (`owntracks` or `traccar`), `events_app` (`mobilizon` or `none`), `push` (boolean), `jellyfin` (boolean). When `jellyfin` is true, `jellyfin.<family>.tinyweb.win` is a proxied `CNAME` and a tunnel ingress host. When it is false, that name is not added. Immich is out of scope for v1 and is not a host.

```json
{
  "status": "issued",
  "replayed": false,
  "published": false,
  "provider": "fake",
  "edge_certificate_ready": false,
  "domain": "smith.tinyweb.win",
  "tunnel": {
    "tunnel_id": "…",
    "account_tag": "…",
    "token": "<cloudflared token>",
    "credentials_file": {}
  },
  "dns": [
    {
      "name": "smith.tinyweb.win",
      "type": "CNAME",
      "content": "<tunnel-id>.cfargotunnel.com",
      "proxied": true,
      "applied": false
    }
  ],
  "certificate": {
    "method": "advanced_certificate_manager",
    "hosts": ["tinyweb.win", "smith.tinyweb.win", "*.smith.tinyweb.win"],
    "status": "ordered",
    "ready": false
  },
  "origin_service": "https://127.0.0.1:443"
}
```

`published: true` means the `CNAME` records were written. `applied: false` means that row was not written. The `fake` provider always returns `published: false` so a dev process cannot look like a public hostname. A certificate warning can remain until `edge_certificate_ready` is true, because issuance is asynchronous. A retry before revoke returns the same tunnel (`replayed: true`) and does not create a second tunnel.

`POST /v1/tunnels/revoke` with `{ "slug": "smith" }` deletes the DNS `CNAME`s and the Cloudflare tunnel. The slug stays reserved. The setup code stays spent once setup was completed. The box can call `POST /v1/tunnels` again with the claim token it already holds.

`POST /v1/setup/complete` forgets the plaintext claim token on the server. The hash remains so the box can still authenticate. The factory code then returns `setup_already_complete` and does not include `claim_token`.

Operator mint (`POST /v1/operator/units`, bearer `TWS_CONTROL_PLANE_OPERATOR_TOKEN`) returns the setup code once. Store it on the sticker, not in git. The database stores only a hash of the code.

## DNS is not a second writer

[`scripts/lib/domains.sh`](../scripts/lib/domains.sh) `node_all_domains` is the hostname list. The control plane shells out to it. Service hosts are explicit proxied `CNAME`s to `<tunnel-id>.cfargotunnel.com`. There is no wildcard DNS record, so a name that is not in the list is not routed through Cloudflare. `jellyfin.<family>.tinyweb.win` is in the list only when Jellyfin is enabled. Immich is out of scope for v1.

[`scripts/vm/tinyweb-subdomain-ddns.sh`](../scripts/vm/tinyweb-subdomain-ddns.sh) can POST its existing webhook body to `POST /v1/ddns`:

```json
{"token": "…", "domain": "smith.tinyweb.win", "wildcard": "*.smith.tinyweb.win", "ipv4": "…", "ipv6": ""}
```

For a reserved family the response is `changed: false` and `status: tunnel-managed`. The home address is not written. An unknown name is `404 not_managed`. This process does not create `A` or `AAAA` records. Do not put `CF_API_TOKEN` on the box, and do not run the DDNS timer for a tunnel family: the timer's job was to point the name at the house, which fights the tunnel.

If an old `A`/`AAAA` record is still present, the Cloudflare provider deletes it while upserting the tunnel `CNAME`.

## Certificates

Universal SSL on `tinyweb.win` covers the apex and one label (`tinyweb.win`, `*.tinyweb.win`). `smith.tinyweb.win` is in that set. `matrix.smith.tinyweb.win` is not. A phone will show a certificate warning on those nested hosts until a deeper certificate exists.

Default method (`TWS_EDGE_CERT_METHOD=advanced`): order one [Advanced Certificate Manager](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/) pack per family. The API requires the zone apex on every pack. The pack hosts are:

- `tinyweb.win`
- `<family>.tinyweb.win`
- `*.<family>.tinyweb.win`

A wildcard covers one more label, which is `matrix.<family>.tinyweb.win` and the other service hosts. The pack is not marked ready until Cloudflare reports it `active`. Issuance is asynchronous.

Equivalent (`TWS_EDGE_CERT_METHOD=total_tls`): enable [Total TLS](https://developers.cloudflare.com/ssl/edge-certificates/total-tls/) on the zone. Total TLS issues a certificate for each proxied hostname, including nested names. It is part of Advanced Certificate Manager. `edge_certificate_ready` stays false here because issuance happens after the DNS record exists.

The wildcard on an advanced pack also covers `jellyfin.<family>.tinyweb.win` when that host is proxied. Total TLS issues a certificate for each proxied hostname, so an enabled Jellyfin host is included there too.

## Jellyfin on the tunnel

Optional Jellyfin uses this same per-box tunnel. First boot sends `jellyfin: true` when `TWS_JELLYFIN` is enabled, and the handoff then includes `jellyfin.<family>.tinyweb.win`. A Jellyfin name on the handoff is not a reason to refuse the tunnel. When Jellyfin is off, the host is not added.

Immich is out of scope for v1. It is not an app, a DNS name, or a tunnel route.

Ordinary Cloudflare HTTP proxy plans can still reject a single request body over 100 MB. That limit is a property of the plan, not a reason to leave Jellyfin off the tunnel.

## Tunnels for Platforms

The operator uses one TinyWeb Cloudflare account. Parents do not create accounts. Each box is one remotely managed tunnel (`config_src: cloudflare`). The [Tunnels for Platforms](https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/) allowance is the first 1,000 tunnels in the account, then $4.50 per additional tunnel per month. Inactive tunnels count. Revoke deletes the tunnel so it does not keep a slot.

The API token on the control-plane host needs:

- Account: Cloudflare Tunnel write (Cloudflare One Connectors write also works)
- Zone: DNS edit, for the `tinyweb.win` zone
- Zone: SSL and certificates edit, for the certificate pack or Total TLS

The box receives only the tunnel token. `cloudflared tunnel run` with `TUNNEL_TOKEN` set uses the remote ingress. The hostname list lives at Cloudflare, not in a config file on the box.

## Box hook

`scripts/install-tinyweb.sh` does not call these scripts. The first-boot setup service does, after it saves the handoff JSON from `POST /v1/tunnels`. `scripts/setup/pre-ship.py` is what William runs before the box ships: it mints the unit, writes the setup code, prints the QR, and enables the setup service. It does not set the family name or the parent password.

```bash
sudo scripts/cloudflared-install.sh
sudo scripts/cloudflared-apply.sh --credentials /etc/tinywebstack/cloudflared/handoff.json
```

`cloudflared-install.sh` installs the package and does not start a tunnel.

`cloudflared-apply.sh` fails if the file is missing, the token is empty, or `published` is not true. It does not create DNS. On success it writes `TUNNEL_TOKEN` to `/etc/tinywebstack/cloudflared/tunnel.env` (mode `0600`) and enables `tinyweb-cloudflared.service`. The token is not placed on the `cloudflared` command line. `--dry-run` validates and prints `service_started=no` and `dns_changed=no`. `--dest-dir` stages those files without calling `systemctl`, for tests and image builds.

Save the whole `POST /v1/tunnels` response as the handoff file, mode `0600`. The script accepts the token at the top level or under `tunnel`.

## Environment

Set these on the control-plane host. None of them are required to run the unit tests. Do not commit values.

| Variable | Required to publish | Purpose |
| --- | --- | --- |
| `CF_API_TOKEN` | yes | Cloudflare API token. Never put this on a family box. |
| `CF_ACCOUNT_ID` | yes | TinyWeb Cloudflare account. |
| `CF_ZONE_ID` | yes | Zone id for `tinyweb.win`. |
| `CF_API_BASE` | no | Default `https://api.cloudflare.com/client/v4`. |
| `TWS_EDGE_CERT_METHOD` | no | `advanced` (default) or `total_tls`. |
| `TWS_CERT_AUTHORITY` | no | `lets_encrypt` (default), `google`, or `ssl_com`. |
| `TWS_BASE_DOMAIN` | no | Default `tinyweb.win`. Must be the zone apex. |
| `TWS_CONTROL_PLANE_PUBLIC_ORIGIN` | no | Default `https://tinyweb.win`. Used only to display setup URLs. |
| `TWS_CONTROL_PLANE_OPERATOR_TOKEN` | to mint units | Factory mint and emergency revoke. |
| `TWS_DDNS_TOKEN` | to accept the DDNS webhook | Shared secret matching `TWS_DDNS_TOKEN` on a box that still points `TWS_DDNS_ENDPOINT` here. Not a Cloudflare token. |
| `TWS_CONTROL_PLANE_DB` | no | SQLite path. Default `controlplane/var/control-plane.sqlite`. Mode `0600`. Holds tunnel tokens. |
| `TWS_CONTROL_PLANE_PROVIDER` | no | `cloudflare` (default) or `fake`. `fake` never reports `published: true`. |
| `TWS_CONTROL_PLANE_HOST` | no | Default `127.0.0.1`. |
| `TWS_CONTROL_PLANE_PORT` | no | Default `8787`. |
| `LOCATION_APP` | no | Default `owntracks` when the tunnel request omits it. |
| `EVENTS_APP` | no | Default `mobilizon`. |
| `TWS_PUSH_ENABLE` | no | Default on. `0` omits `push.<family>`. |

`GET /v1/slugs/{slug}` and `POST /v1/setup/claim` are public apart from the setup code. Put the process behind the operator's proxy and rate-limit those two routes. The setup code is a long random value.

Run it with:

```bash
python -m tinyweb_controlplane
```

Bind it on localhost and put the operator's reverse proxy in front of it when it is actually placed on the control-plane host. The database directory must not be world-readable.

## Tests

From the repository root, with the package installed (`pip install -e 'controlplane[test]'`):

```bash
pytest controlplane/tests -q
```

`scripts/validate.sh` runs the same tests. They use the fake provider and a temporary database. They do not call Cloudflare.
