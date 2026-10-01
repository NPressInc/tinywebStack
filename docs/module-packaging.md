# Module packaging (S5.4)

Both hand-deployed Python packages in `family/` are proper installable
packages with `pyproject.toml`, and the Synapse family module now survives
`yunohost app upgrade synapse` via a post-upgrade re-apply script. This doc is
the reference for how installation works, what the env knobs are, and how to
recover after a Synapse app upgrade.

Lab flow is unchanged: the same `remote-run.sh` / `family-init.sh` commands
work byte-for-byte, and every new env var defaults to the previous behavior.

## Packages

| Package | Dir | Runtime deps | Notes |
|---|---|---|---|
| `tinywebstack-family` | `family/synapse_module/` | none (stdlib only) | Synapse spam-checker / third-party-rules module. Loaded by Synapse via dotted path `tinywebstack_family.module.FamilySpamCheckerModule` from the conf.d snippet — deliberately ships **no** console scripts so nothing extra lands in the Synapse venv. |
| `tinywebstack-calendar` | `family/calendar_module/` | none | CalDAV setup/sharing/verify CLI. Optional extras: `[verify]`/`[test]` pull `caldav` + `vobject` (only `verify.py` imports them). Console scripts: `tinywebstack-calendar-setup`, `tinywebstack-calendar-verify` (thin wrappers over `setup:main` / `verify:main`). The shell scripts keep calling `python -m tinywebstack_calendar.setup|verify` directly. |

Both use the `setuptools` build backend (`[build-system]` in each
`pyproject.toml`) and build offline with a plain `pip install` /
`pip wheel`.

Build wheels on the control machine (optional — the node normally installs
from synced source):

```bash
python -m pip wheel --no-deps -w dist family/synapse_module family/calendar_module
# dist/tinywebstack_family-0.1.0-py3-none-any.whl
# dist/tinywebstack_calendar-0.1.0-py3-none-any.whl
```

## Install path on the node

`scripts/vm/install-family-module.sh` (unchanged entry points:
`remote-run.sh "$IP" install-family-module.sh <domain>` and
`family-init.sh`) now installs a **proper wheel, not an editable copy**:

```
pip install --upgrade --no-deps --force-reinstall <source-or-wheel>
```

- Default source: the rsynced `family/synapse_module` directory (what
  `remote-run.sh` already ships to `/opt/tinywebstack`). `--force-reinstall`
  keeps site-packages in sync with the synced source on every run (pip would
  otherwise no-op on the same version and leave a stale module behind) — the
  script stays idempotent, and the conf.d snippet / policy file / restart
  logic are identical to before.
- `TWS_FAMILY_MODULE_WHEEL=/path/to.whl` switches the install source to a
  prebuilt wheel (built on the control machine, copied up, or vendored). The
  wheel is installed `--no-deps`; the package has no runtime deps either way.
- After installing, the script **verifies importability** with the venv's own
  python (`import tinywebstack_family`) and aborts loudly instead of letting
  Synapse restart without the module.

Post-install artifacts are unchanged: `/etc/tinywebstack/family-policy.json`
(empty skeleton if missing), `/etc/matrix-synapse/conf.d/tinywebstack-family.yaml`
(idempotent rewrite), optional `TWS_MATRIX_SERVER` touch in
`dashboard.env`, Synapse restart.

`DRY_RUN=1` logs every mutation (pip call, policy, snippet, restart) and
touches nothing.

### Sandbox / dev overrides

For tests and offline dev runs (never needed in the lab flow):
`TWS_SYNAPSE_PIP`, `TWS_SYNAPSE_CONF_D`, `TWS_ALLOW_NONROOT=1`,
`TWS_SKIP_RESTART=1`. All default to the production paths/behavior.

## Surviving `yunohost app upgrade synapse`

A Synapse app upgrade recreates the app venv, which **silently drops** the
pip-installed `tinywebstack_family` — spam-checker rules stop enforcing while
everything else looks healthy (v1.1 punch item, `docs/production-setup.md`).

Recovery is one command, from the control machine:

```bash
scripts/vm/remote-run.sh "$IP" family-module-post-upgrade.sh <MAIN_DOMAIN>
# or on the node:
sudo bash /opt/tinywebstack/vm/family-module-post-upgrade.sh <MAIN_DOMAIN>
```

What it does:

1. Finds the Synapse venv (`/var/www/synapse/venv`, then the
   `matrix-synapse` candidates; override with `TWS_FAMILY_MODULE_VENV`).
2. `venv/bin/python -c 'import tinywebstack_family'` — if it imports, log
   `nothing to do` and exit 0 (**healthy no-op**, safe to run anytime).
3. If missing, re-run `install-family-module.sh` with the same args (override
   the installer path with `TWS_FAMILY_MODULE_INSTALLER`), then re-verify
   importability and fail loudly if still broken.

Because it is a no-op when healthy, the two recommended invocations are:

- **Manual:** run it right after `sudo yunohost app upgrade synapse`
  (alongside the existing §9 runbook step — it replaces the "re-run
  install-family-module.sh" instruction; the post-upgrade script calls that
  script for you once it has detected the wipe).
- **Optional hook note:** YunoHost exposes no supported post-app-upgrade hook
  that reliably sees the recreated venv (`app upgrade` scripts run against
  the new venv after YunoHost rebuilds it, and custom `restore`-style hooks
  aren't invoked on upgrades). The practical, dependency-free option is a
  weekly cron on the node that just checks and no-ops unless wiped — it only
  mutates anything when the module is actually missing:

  ```bash
  # /etc/cron.weekly/tinywebstack-family-module-check (root, node):
  # #!/bin/sh
  # exec /usr/bin/bash /opt/tinywebstack/vm/family-module-post-upgrade.sh \
  #   home.example.com >>/var/log/tinywebstack-family-module.log 2>&1
  ```

  (Only worth wiring if you *don't* already re-run it manually after every
  Synapse upgrade — the cron re-installs from the last rsynced source tree.)

## How the lab flow stays byte-for-byte

- `family-init.sh` still calls `install-family-module.sh "$MAIN_DOMAIN"`;
  `remote-run.sh` still rsyncs `family/` + `scripts/` and runs the same
  script name (plus the new `family-module-post-upgrade.sh`, registered in
  `scripts/lib/remote-node.sh` like its sibling).
- Every new env var (`TWS_FAMILY_MODULE_WHEEL`, the sandbox knobs) defaults to
  the old behavior; nothing in `config/defaults.env` changes lab values.
- TLS/insecure-default behavior untouched.
- `setup-family-calendars.sh` / `verify-calendar-e2e.sh` keep their
  `python -m tinywebstack_calendar.*` invocations; the console scripts are
  additive.

## Tests (mock real use, run by `scripts/validate.sh`)

`family/synapse_module/tests/test_packaging.py`

- Builds each package from source with the real build backend
  (`pip install --target --no-deps --no-build-isolation` → real wheel from
  `pyproject.toml`; works fully offline, skips rather than fails if no build
  backend *and* no network).
- Imports `tinywebstack_family` / `tinywebstack_calendar` from the installed
  site dir with the interpreter isolated (`-S`, cwd outside the source tree)
  so an editable dev install can't fake a pass.
- Runs the console entry points from the built wheel:
  `tinywebstack-calendar-setup --help` (asserts the real `--occ-path`
  surface) and `tinywebstack-calendar-verify --help` (skips if `caldav`
  isn't importable offline).
- Guards the packaging contract: family module has zero runtime deps and no
  console scripts; calendar declares its extras and scripts; both declare a
  build-system.

`family/synapse_module/tests/test_post_upgrade_script.py`

- Builds a sandboxed fake node (`lib/`, `vm/`, `family/` copies) plus a fake
  Synapse venv whose `pip` stub records calls and installs by copying the
  package, and whose `python` stub is isolated.
- Wipe detection → re-install invoked, module importable afterwards,
  conf.d snippet + policy file written.
- Healthy no-op → no pip call, no installer run at all.
- `DRY_RUN` on a wiped tree → nothing written, still reports MISSING.
- `install-family-module.sh` direct: two runs idempotent (second reports
  snippet unchanged), `DRY_RUN` writes nothing, snippet content contract
  (dotted module path, `policy_path`, E2EE off) parses as YAML.

## CI

`.github/workflows/ci.yml` installs both packages with their `[test]` extras
via the existing `pip install -e` lines (validate.sh handles it), so the
packaging tests exercise the same `pyproject.toml` files CI already consumes.
No CI change was needed.
