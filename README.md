# tinywebStack

A self-hosted family app ecosystem built on YunoHost and Matrix (Synapse), with a thin family layer on top. Families use the **TinyWeb app** and **parent dashboard** (`/family/`); open-source backends (Synapse, OwnTracks Recorder, Nextcloud, Mobilizon) stay on the box. See [PLAN.md](PLAN.md).

Priority 1 is unboxing: a parent plugs in the box and finishes in the app. That path is [docs/UNBOXING.md](docs/UNBOXING.md). The operator runbook below is not the customer path.

Store packaging for the phone app is in [docs/APP_STORES.md](docs/APP_STORES.md). The app is not submitted to the App Store or Google Play.

## Install on a single machine

Production and lab nodes can be provisioned on the box itself (no control machine):
`sudo ./scripts/install-tinyweb.sh` — see [docs/production-setup.md](docs/production-setup.md) §2
and [docs/test-nodes.md](docs/test-nodes.md) (lab one-box section).

## Test nodes on `spark`

Scripts and runbook for two YunoHost KVM test VMs and Matrix federation allowlists: [docs/test-nodes.md](docs/test-nodes.md). After PR #1, see spark-specific fixes (arm64, libvirt system URI, lab CA, unattended YunoHost) in that doc.
