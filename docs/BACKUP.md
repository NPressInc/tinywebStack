# Backups

Parents use **Backups** on the family dashboard (`https://<main-domain>/family/backup`). That page is the only family-facing control. It starts a backup, shows whether it is running or why it failed, and lists the backups it has made. Kids cannot open it.

Installing the dashboard copies the helper and the YunoHost hooks. It does **not** start a backup and it does **not** enable a timer. Automatic backups stay off until a parent saves a schedule on that page.

A backup that remains on this box is **not** a spare copy. The page says so. If the disk dies, the archive dies with it. Download it, copy it to a disk under `/mnt`, `/media`, or `/run/media`, or `scp` it to another computer.

This work does **not** restore a live box from the dashboard. There is no restore button. Restoring replaces family data, and YunoHost will not restore an app that is already installed. The supported recovery is a YunoHost restore onto a **replacement** computer, before first-time setup. The commands below are the real ones. Nothing in the dashboard runs them.

## What a TinyWeb backup asks YunoHost to do

The root helper runs one command, with a fixed argument list (no shell):

```bash
yunohost backup create \
  --name tinyweb-YYYYMMDD-HHMMSS \
  --description "TinyWeb family backup" \
  --system conf_ldap conf_ynh_settings conf_ynh_certs conf_manually_modified_files conf_tinywebstack \
  --apps synapse element nextcloud mobilizon owntracks
```

`--apps` lists only family apps that are actually installed. `traccar` is included when that app is installed instead of OwnTracks. `jellyfin` and `immich` are never passed. An empty `--system` is never used: that would also select `data_multimedia` (`/home/yunohost.multimedia`), `data_home`, and `data_mail`.

Optional system hooks (`conf_ynh_certs`, `conf_manually_modified_files`) are passed only when that hook file exists. `conf_ldap`, `conf_ynh_settings`, and `conf_tinywebstack` are required. If one of those is missing, the job fails and no archive is kept as successful.

Archives are YunoHost tar archives at `/home/yunohost.backup/archives/tinyweb-YYYYMMDD-HHMMSS.tar`.

## Coverage

Checked against upstream YunoHost and the app backup scripts (YunoHost `dev` hooks, and the `master` `scripts/backup` of each app) in November 2026.

| Family data | In a TinyWeb backup | How |
|-------------|---------------------|-----|
| Family accounts (users, groups, password hashes) | Yes | System hook `conf_ldap`: `slapcat` LDIF of `cn=config` and `dc=yunohost,dc=org`. Not a copy of the live `/var/lib/ldap` files. |
| Who can use which app | Yes | System hook `conf_ynh_settings` includes `/etc/yunohost/permissions.yml`, domains, and YunoHost settings. |
| TLS certificates | Yes, when the hook exists | `conf_ynh_certs`. |
| Chats | Yes, when Synapse is installed | `synapse_ynh` `scripts/backup`: `ynh_psql_dump_db` (a real PostgreSQL dump) plus `ynh_backup` of `$data_dir` (media/uploads) and `/etc/matrix-synapse`. Upstream warns that a copy is cleaner if Synapse is stopped. TinyWeb does **not** stop chat for a parent backup. The database dump is consistent; uploaded files are copied live, which is what that script declares. |
| Encrypted chat on a new phone | Only with the recovery key | The Synapse dump includes server-side key-backup blobs if the TinyWeb app created a key backup. The recovery key was shown on the phone and is **not** in this archive. Without it, old encrypted history cannot be read on a new phone. |
| Element settings | Yes, when Element is installed | Element’s backup is the install and its nginx/systemd files. Chat history is in Synapse, not Element. |
| Calendars | Yes, when Nextcloud is installed | `nextcloud_ynh` `scripts/backup`: `ynh_mysql_dump_db` plus `$data_dir` and the install. Calendar events live in that database dump. The data directory is included too, so files stored in Nextcloud make the archive larger. |
| Events | Yes, when Mobilizon is installed | `mobilizon_ynh` `scripts/backup`: `ynh_psql_dump_db` plus `$data_dir` (uploads), install, nginx, and the systemd unit. |
| Location history | Yes, when OwnTracks or Traccar is installed | `owntracks_ynh` `scripts/backup` declares `$data_dir` with `ynh_backup --is_big` (included in a normal backup; skipped only for YunoHost’s pre-upgrade safety backup). That is a file copy of the recorder store, not a separate database dump. Traccar is passed through the same way when it is the installed location app. Kid publish passwords in `/etc/tinywebstack/owntracks-kids.json` are in the TinyWeb hook, not in the OwnTracks app archive. |
| Family rules (allow lists, quiet hours, roles) | Yes | Hook `conf_tinywebstack` snapshots `/etc/tinywebstack/permissions.db` with SQLite’s backup API into the YunoHost work directory. The live database file is not the archive source. |
| Phone sign-in records | Yes | Same hook, same SQLite backup API, for `/etc/tinywebstack/app-devices.db` (token hashes and enrollment-code hashes, not a second copy of the live file). |
| TinyWeb settings and service config | Yes | The same hook copies `/etc/tinywebstack` settings and secrets (including `dashboard.env`, `secrets/`, the Synapse admin token, and the Matrix login-ticket secret), TinyWeb nginx snippets, and TinyWeb files under `/etc/matrix-synapse/conf.d`. Paths that are symlinks pointing outside those directories are not followed. |
| Movies, shows, Jellyfin metadata | **No** | `jellyfin` is not in `--apps`. `jellyfin_ynh` would otherwise back up `$install_dir` and `$data_dir` (metadata and `jellyfin.db` can be large). This does not depend on any open Jellyfin change. |
| Shared media folder | **No** | System hook `data_multimedia` (`/home/yunohost.multimedia`) is not selected. A `.nobackup` file in that folder is a YunoHost feature for people who run a full system backup; TinyWeb does not rely on it because it never selects that hook. |
| Immich or other photo libraries | **No** | `immich` is not in `--apps`. |
| Mail and Linux home directories | **No** | `data_mail` and `data_home` are not selected. |
| Installer password file | **No** | `~/.tinywebstack-secrets/passwords.env` on the computer that installed the box is not on the box. |
| Dashboard program files | Not as their own archive | `/opt/tinywebstack` and `/opt/tinywebstack-family-dashboard` are reinstalled from a checkout after a restore. Synapse’s own archive includes the Synapse virtualenv as it was at backup time, which may contain the family module. Still re-apply it after restore (below). |

### Copy Jellyfin media yourself

Plug in another disk and copy the folder. This page does not run the copy and it does not delete anything in that folder:

```bash
rsync -aH /home/yunohost.multimedia/ /media/usb/multimedia/
```

Do not add `--delete` unless you mean to remove files on the destination that are already gone from the source.

## Jobs, schedule, disk space, retention

- **Back up now** returns as soon as the helper process has started. The helper is a separate process, so a dashboard restart does not kill it. The page shows Waiting, Checking disk space, Backing up, Removing old backups, Finished, or Failed.
- If the helper dies or the box restarts mid-backup, the next page load marks the job failed. A failed job is not listed as a usable archive. If YunoHost exits successfully but the archive has no `conf/tinywebstack/manifest.json`, the job is failed and that archive name is passed to `yunohost backup delete` so it is not left looking like a finished family backup.
- A second backup is rejected while one is queued or running. The helper also holds a lock, so two overlapping runs cannot both proceed.
- A backup is refused when free space on the archive disk is under the parent’s limit (default 2 GB, never under 512 MB even if the settings file is wrong).
- Schedule choices are off (default), daily, or weekly, at a chosen hour and minute. Saving **off** disables only `tinywebstack-family-backup.timer`. Saving a schedule writes that unit and enables it. `Persistent=false`, so turning it on does not immediately run a missed backup.
- After a successful backup, retention may delete **only** archives this tool recorded as successful, named `tinyweb-YYYYMMDD-HHMMSS`, that are regular files inside `/home/yunohost.backup/archives` (symlinks are left alone). Deletion is `yunohost backup delete NAME`, at most 20 names per run. The newest backup is always kept. Other YunoHost archives are not touched.

## Replace a dead box

Do this on a **replacement** computer. Do not run it against the family’s live box from the dashboard.

1. If the old box still starts, copy the archive off it before you trust any repair. From another computer, with an admin login (not a child’s):

   ```bash
   scp USER@smith.tinyweb.win:/home/yunohost.backup/archives/tinyweb-YYYYMMDD-HHMMSS.tar .
   ```

   Or use **Download** or **Copy to that folder** on the backup page while signed in as a parent. Download is streamed by the dashboard; it is not a file under the public web root. A multi-gigabyte archive is easier to copy with `scp` or onto a plugged-in disk if a browser times out.

2. Install Debian and YunoHost on the replacement computer. **Skip postinstall.** YunoHost’s install notes say to restore a backup instead of the initial configuration when you are recovering a server: [Install on top of Debian](https://doc.yunohost.org/admin/get_started/install_on/on_top_of_debian/) and [Backups](https://doc.yunohost.org/admin/backups/).

3. Put the file at `/home/yunohost.backup/archives/tinyweb-YYYYMMDD-HHMMSS.tar` on the new computer (directory owned by root, mode `700` is YunoHost’s usual layout).

4. As root on the new computer:

   ```bash
   yunohost backup restore tinyweb-YYYYMMDD-HHMMSS
   ```

   The name has no `.tar`. This restores every system part and app stored in that archive. That includes LDAP accounts, permissions, certificates, and the TinyWeb hook. The hook runs with **system `python3`**, not the dashboard virtualenv (that virtualenv does not exist yet). It runs `tinyweb_restore.py` from inside the archive, copies allowlisted settings back, and replaces `permissions.db` and `app-devices.db` from the SQLite snapshots. It refuses a symlink in any component of a destination path and does not write anywhere outside that allowlist.

5. Do not install Synapse, Nextcloud, Mobilizon, OwnTracks, or Element on the new computer first. YunoHost refuses to restore an app that is already installed.

6. After that restore has finished, put the dashboard program back from a current checkout. This step is what creates `/opt/tinywebstack-family-dashboard`. It is not required for the restore hook.

   ```bash
   sudo bash scripts/vm/install-family-dashboard.sh <main-domain>
   sudo bash scripts/vm/family-module-post-upgrade.sh <main-domain>
   ```

   Re-running the dashboard install does not enable the backup timer and does not start a backup. If the parent had saved a schedule, the settings file is part of the TinyWeb hook and a later save (or a manual `apply-schedule`) turns the timer back on. Confirm the schedule is what you want before you rely on it.

7. Sign in at `https://<main-domain>/family/` as a parent. Check one chat, one calendar event, and one event before you treat the new box as the home. Encrypted history on a new phone still needs the recovery key.

8. Copy `/home/yunohost.multimedia` back yourself if this family used Jellyfin. It was not in the archive.

## Restore: limits

Restore is a YunoHost restore on a replacement computer. The dashboard does not start it, and this repository's tests do not run it against a live box.

- The restore hook is bootstrapped from the archive. It uses system `python3` and `conf/tinywebstack/tinyweb_restore.py`. It does not use `/opt/tinywebstack-family-dashboard`, which is installed only after restore.
- It writes only allowlisted paths: `/etc/tinywebstack/`, TinyWeb files named `tinywebstack*` under Synapse `conf.d` and nginx `conf.d`, and the two TinyWeb hook scripts. A path such as `/etc/passwd` is refused even though it sits under `/`.
- It refuses a symlink in any component of a destination path and writes files by opening the directory with `O_NOFOLLOW` and replacing a temporary file in that directory.
- It restores SQLite from the snapshots in the archive, not by copying a live database file back into place.
- It does not restore Jellyfin, Immich, `/home/yunohost.multimedia`, mail, Linux home directories, or the installer password file. Those were not in the archive.
- It does not restore Matrix recovery keys. Encrypted chat on a new phone still needs the key that was shown on the old phone.
- YunoHost will not restore an app that is already installed. Do not install Synapse, Nextcloud, Mobilizon, OwnTracks, or Element before `yunohost backup restore`.
- A successful hook does not mean the new box is ready to use. Install the dashboard and re-apply the family module afterward, then check a chat, a calendar event, and an event while signed in as a parent.

## Security

- Every backup route checks the parent SSO header (`YNH_USER`). A child, a missing login, and a client-supplied `Remote-User` are rejected.
- State-changing forms use the dashboard CSRF token.
- Archive names must match `tinyweb-YYYYMMDD-HHMMSS`. Paths, `..`, and shell characters are rejected.
- Download and copy only succeed for archives this tool recorded as successful. The helper opens the tar with `O_NOFOLLOW` and checks the real path stays in the archive directory.
- Copy destinations must be an existing real directory under `/mnt/`, `/media/`, or `/run/media/`.
- The helper’s sudoers line is the script path only. The script accepts a fixed subcommand list and `exec`s Python with separate arguments.
- Job errors are redacted (password, token, bearer, `tws_` values) before they are stored or shown. The page sends `Cache-Control: no-store`.
- The restore hook refuses manifest paths outside the TinyWeb settings, TinyWeb nginx snippets, and TinyWeb Synapse snippets. It does not delete unrelated files.

## Test checklist

Automated in CI (no YunoHost, no live restore):

- Parent required; child and missing login are rejected; `Remote-User` is ignored.
- CSRF required. `POST /backup/restore` does not exist.
- Bad archive ids and copy paths outside `/mnt`, `/media`, and `/run/media` are rejected.
- A failed job and a failed download do not show a planted password or `tws_` token.
- Low disk space and an already-running job do not start another backup.
- **Back up now** returns while the helper is still running.
- A dead worker pid is marked failed after a restart.
- Retention deletes only managed names, keeps the newest, caps a run at 20, and does not follow a symlink onto another file.
- The YunoHost command never includes Jellyfin, Immich, `data_multimedia`, `data_home`, or `data_mail`.
- The TinyWeb hook snapshots SQLite with the backup API, skips a settings symlink that points outside, and refuses a manifest path that escapes.
- The default schedule is off. The install script does not enable `tinywebstack-family-backup.timer` and does not run `yunohost backup create`.
- The privileged shell script rejects unknown commands and does not evaluate arguments.

Still required on a real YunoHost box (not run by this change):

- `yunohost backup create` through **Back up now**, then `tar -tvf` the archive and confirm it contains a PostgreSQL or MySQL dump for each installed app, `conf/ldap/*.ldif`, and `conf/tinywebstack/snapshots/permissions.db`, and that it does **not** contain `home/yunohost.multimedia` or a Jellyfin library.
- Confirm a second click while the first backup runs is rejected, and that a nearly full disk is rejected.
- Download or `scp` the archive to a different disk. Delete a local copy of a test file and confirm the on-box archive is not your only copy.
- On a **spare** machine, skip postinstall, run `yunohost backup restore`, then the two re-apply commands above. Sign in as a parent and open a chat, a calendar event, and an event. Do not run that restore against the family’s live box.
- Turn the schedule on, confirm the timer unit is enabled, turn it off, confirm that unit is disabled and that no other timers changed.
- Copy `/home/yunohost.multimedia` with the `rsync` line above if this family uses Jellyfin, and confirm a core backup did not grow by the size of that library.
