# Optional Jellyfin

Jellyfin is **off** unless `TWS_JELLYFIN=1`. A family box that leaves it off is unchanged: no extra app, domain, permission, or dashboard block.

TinyWeb does not play media and does not rebuild Jellyfin’s dashboard. Parents add libraries, metadata, playback settings, and each person’s library access in **Jellyfin’s own dashboard**. The TinyWeb dashboard and app only show the server address and how to open it.

Checked against the official package [YunoHost-Apps/jellyfin_ynh](https://github.com/YunoHost-Apps/jellyfin_ynh) `master` on 2026-11-10 (package **12.4~ynh1**, LDAP plugin **24.0.0.0**).

## What gets installed

`scripts/vm/install-jellyfin.sh` (from `family-init.sh`) runs only when Jellyfin is requested. It installs the catalog app `jellyfin` on:

`https://jellyfin.<family>.tinyweb.win/`

That name matches the other service hosts (`matrix.`, `nextcloud.`, `mobilizon.`). With `TWS_JELLYFIN=1` it is included in `node_all_domains` and on the family's Cloudflare Tunnel. Bootstrap, lab certs, per-domain Let’s Encrypt, and the `*.<family>.tinyweb.win` certificate link pick it up. If the family certificate is a wildcard for the main name, the installer copies that certificate onto the Jellyfin host. Immich is out of scope for v1. Large Jellyfin media stays out of the core family backup; `jellyfin` is not passed to `yunohost backup create`. See [BACKUP.md](BACKUP.md).

The YunoHost package already creates the shared media directory and gives Jellyfin access to it. Put files under `/home/yunohost.multimedia/share` and add libraries from Jellyfin’s dashboard. TinyWeb does not scan, import, or transcode.

Native Jellyfin apps are the way to watch. The browser is a fallback. Discovery UDP ports 1900 and 7359 stay closed, which is the package default; clients use the URL.

## Sign-in is the family password, not single sign-on

The package manifest sets the catalog flags `ldap = true` and `sso = true`. The same package sets `main.auth_header = false`, tells the installer that Jellyfin has its own login, and documents in `doc/ADMIN.md` that people log in through LDAP.

What that means here:

- A parent or child opens the Jellyfin app or the Jellyfin website and types their TinyWeb username and password.
- YunoHost does not hand Jellyfin a logged-in session. Matching passwords are not single sign-on.
- The packaged LDAP plugin checks the YunoHost directory. Its search filter is `(permission=cn=jellyfin.main,ou=permission,dc=yunohost,dc=org)`.
- `jellyfin.admin` is what makes Jellyfin show its administration panel. Parents receive it. Children do not.
- The URL itself is public (`visitors`) because phone and TV clients have to reach Jellyfin’s login. Being able to open the page is not the same as being allowed to sign in.

The plugin is shipped with `AllowPassChange` false, so Jellyfin does not keep a second password. A password reset in TinyWeb/YunoHost is the password Jellyfin will check next time. Removing a YunoHost account stops that LDAP login. TinyWeb does not delete a leftover Jellyfin profile; a parent can remove it in Jellyfin’s user list. Do not create a local Jellyfin user with the built-in password provider. That account would sit outside LDAP, and TinyWeb does not disable that provider (doing so can lock the server out of its own admin login).

No Jellyfin API key is created, stored, or sent to the TinyWeb app.

## Children do not start with libraries

Two separate controls, both required:

1. **Who may sign in.** The installer grants `jellyfin.main` to the `parents` group and removes it from `kids`, `all_users`, and `federation-test`. A child who is not on `jellyfin.main` fails the LDAP search. The official Jellyfin app uses that same login, so it does not get a session and does not receive a library list. Another family’s accounts are not in this box’s directory, and the federation-test group is not granted the permission.
2. **What a new Jellyfin account can see.** The packaged `LDAP-Auth.xml` sets `EnableAllFolders` to true and includes two hardcoded library ids. On a requested install, TinyWeb rewrites that to `EnableAllFolders` false and an empty folder list, then restarts Jellyfin if the file changed. Plugin 24’s source applies that flag when it creates a user. If the file does not have those elements, the installer stops instead of pretending the default is safe.

Upstream [jellyfin-plugin-ldapauth#221](https://github.com/jellyfin/jellyfin-plugin-ldapauth/issues/221) (plugin 23 on server 10.11) reports that `EnableAllFolders` was ignored and new users still received every library. Plugin 24.0.0.0’s changelog does not mention a fix, and this repo has not smoke-tested playback on Jellyfin 12.4. The permission gate in (1) does not depend on that bug. The folder flag in (2) is the packaged setting parents should confirm, not a second TinyWeb screen.

When a parent wants one child to watch something:

1. In Jellyfin’s dashboard, confirm the LDAP plugin’s “access to all libraries” box is off.
2. Allow that child only: `yunohost user permission add jellyfin.main USERNAME`
3. Have the child sign in once, then in Jellyfin → Dashboard → Users turn on only the libraries they should see. If “all libraries” is on, turn it off before treating the account as ready.

Family quiet hours are a Matrix rule. They are **not** applied to Jellyfin. Jellyfin’s access schedules are not set by TinyWeb.

## Where people see it

- Parent dashboard (`/family/`): a short Jellyfin card with the address, only after install wrote `TWS_JELLYFIN_URL`.
- TinyWeb app: a Jellyfin tile only when `/.well-known/tinywebstack-family.json` has `jellyfin.enabled`. The tile copies the Jellyfin address (not the family home URL) and can open the site in the browser. `jellyfin.sso` is false. The document has no API key.
- Jellyfin’s own dashboard: libraries, users’ media access, metadata, and playback.

## Enable it

On a box you mean to use for media, before or after the rest of TinyWeb:

```bash
# /etc/tinywebstack/tinyweb.env
TWS_JELLYFIN=1
```

Then `scripts/vm/install-jellyfin.sh <family>.tinyweb.win` as root, or a fresh `install-tinyweb.sh` / `family-init.sh` with that setting. Re-running is safe. `TWS_JELLYFIN=0` (the default) does not call `yunohost`.

The installer reads `TWS_JELLYFIN` from the environment. If it is unset, it reads the `TWS_JELLYFIN=` line in `/etc/tinywebstack/tinyweb.env`. An exported value wins over the file.

First boot sends `jellyfin: true` on `POST /v1/tunnels` only when `TWS_JELLYFIN` is already set. The parent dashboard does not edit DNS. It shows the Jellyfin card after this installer writes `TWS_JELLYFIN_URL`.

Turning Jellyfin on after setup is the same installer command. If `cloudflared/handoff.json` is already on the box, `scripts/cloudflared-hosts.sh` asks the control plane to add `jellyfin.<family>.tinyweb.win` (proxied `CNAME` and tunnel ingress) and then runs `scripts/cloudflared-apply.sh`. The call uses the claim token stored at setup (`cloudflared/claim-token`). It does not send the setup code, which was consumed when setup finished. Apply refuses unless the handoff says `published` is exactly true. The `fake` provider never says that.

Turning it off is `TWS_JELLYFIN=0` in the environment, or that line in `tinyweb.env`, and the same installer command. When the saved handoff already has the Jellyfin host, that removes it and re-runs apply. It still does not call `yunohost`, and it does not uninstall the app. A box with no handoff yet (first boot, or a lab box that is not on the tunnel) leaves the tunnel unchanged. So does a run where `TWS_JELLYFIN` was never set and the handoff has no Jellyfin host: the default of 0 is not a request to delete DNS.

Jellyfin is not a required service. The package’s own runtime note is about 100 MB before playback; transcoding is configured in Jellyfin and can be much heavier on an 8 GB NAS or mini PC. Leave it off on boxes that should not spend that memory.

Swiftfin (iOS/tvOS) needs TLS 1.2. The package’s admin notes say YunoHost’s NGINX compatibility should be “Intermediate”, not “Modern”, if that client fails to play.

## Real-hardware smoke (not run in CI)

On a spare machine, not a lab VM that must stay off:

1. Install with `TWS_JELLYFIN=1` and open `https://jellyfin.<family>.tinyweb.win/`.
2. Sign in as a parent in a browser and in an official Jellyfin phone or TV app. Both should ask for the username and password.
3. Confirm a child who was not granted `jellyfin.main` cannot sign in from that native app.
4. In the LDAP plugin page, confirm “access to all libraries” is off and no default libraries are selected.
5. Grant `jellyfin.main` to one child, sign in once, and confirm that user’s library access in Jellyfin. If every library is on, turn it off and treat upstream issue 221 as still open on this version.
6. Confirm the TinyWeb dashboard and app show the address and do not show an API key.
7. On a second box with Jellyfin left off, confirm `yunohost app list` has no `jellyfin` and the family home page has no Jellyfin card.
