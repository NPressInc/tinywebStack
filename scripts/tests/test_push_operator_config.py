"""TinyWeb shared APNs/FCM credentials. Fixtures are fake; delivery is not simulated."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "lib" / "push_operator_config.py"
HOOK = ROOT / "scripts" / "vm" / "configure-push-credentials.sh"
CANARY = "CANARY-PRIVATE-KEY-MATERIAL-9f3a2c"
KEY_ID = "ABCD123456"
TEAM_ID = "TEAM123456"


def _load_module():
    spec = importlib.util.spec_from_file_location("push_operator_config", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


CFG = _load_module()


def _pem(body: str = CANARY) -> str:
    return f"-----BEGIN PRIVATE KEY-----\n{body}\n-----END PRIVATE KEY-----\n"


def _fcm(project: str = "tinyweb-push-test", body: str = CANARY) -> str:
    return json.dumps(
        {
            "type": "service_account",
            "project_id": project,
            "private_key_id": "test-only",
            "private_key": _pem(body),
            "client_email": f"push-test@{project}.iam.gserviceaccount.com",
            "token_uri": "https://oauth2.googleapis.com/token",
        }
    )


def _base_env(**extra: str) -> dict[str, str]:
    env = {
        "TWS_APNS_KEY_ID": KEY_ID,
        "TWS_APNS_TEAM_ID": TEAM_ID,
        "TWS_APNS_KEY": _pem(),
        "TWS_FCM_SERVICE_ACCOUNT_JSON": _fcm(),
    }
    env.update(extra)
    return env


def _assert_no_secret(text: str) -> None:
    assert CANARY not in text
    assert "BEGIN PRIVATE KEY" not in text
    assert "private_key" not in text


def test_default_source_is_shared_tinyweb(tmp_path: Path) -> None:
    creds = CFG.load_push_credentials(_base_env(), tmp_path)
    assert creds.source == CFG.SHARED_SOURCE
    assert creds.apns_platform == "production"
    assert creds.ios_app_id == "win.tinyweb.tinyweb.ios"
    assert creds.android_app_id == "win.tinyweb.tinyweb.android"
    assert creds.fcm_project_id == "tinyweb-push-test"
    assert creds.apns_keyfile == CFG.default_apns_keyfile(tmp_path)


def test_loads_from_operator_env_and_shared_files(tmp_path: Path) -> None:
    push = CFG.shared_push_dir(tmp_path)
    push.mkdir(parents=True)
    (push / CFG.SHARED_APNS_NAME).write_text(_pem(), encoding="utf-8")
    (push / CFG.SHARED_FCM_NAME).write_text(_fcm(), encoding="utf-8")
    operator = push / CFG.OPERATOR_ENV_NAME
    operator.write_text(
        f"TWS_APNS_KEY_ID={KEY_ID}\nTWS_APNS_TEAM_ID={TEAM_ID}\n# {CANARY} must not leak\n",
        encoding="utf-8",
    )
    os.chmod(operator, 0o600)
    creds = CFG.load_push_credentials({}, tmp_path)
    assert creds.apns_key_id == KEY_ID
    assert creds.apns_team_id == TEAM_ID
    assert creds.apns_write_pem is False
    assert creds.fcm_write_json is False


def test_missing_operator_keys_fail_without_echoing_secrets(tmp_path: Path) -> None:
    env = {"TWS_APNS_KEY": _pem(), "TWS_FCM_SERVICE_ACCOUNT_JSON": _fcm()}
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials(env, tmp_path)
    err = raised.value
    message = str(err)
    assert "Delivery is not configured" in message
    assert "TWS_APNS_KEY_ID" in err.missing
    assert "TWS_APNS_TEAM_ID" in err.missing
    _assert_no_secret(message)
    assert not CFG.default_apns_keyfile(tmp_path).exists()
    assert not (tmp_path / "sygnal.yaml").exists()


def test_missing_both_vendor_secrets_names_them(tmp_path: Path) -> None:
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials({}, tmp_path)
    missing = set(raised.value.missing)
    assert "TWS_APNS_KEY" in missing
    assert "TWS_APNS_KEY_ID" in missing
    assert "TWS_APNS_TEAM_ID" in missing
    assert "TWS_FCM_SERVICE_ACCOUNT_JSON" in missing
    assert "not used" in str(raised.value)
    assert raised.value.source == "tinyweb"


def test_legacy_per_family_key_is_not_the_default(tmp_path: Path) -> None:
    legacy = CFG.legacy_apns_path(tmp_path)
    legacy.parent.mkdir(parents=True)
    legacy.write_text(_pem(), encoding="utf-8")
    env = {
        "TWS_APNS_KEY_ID": KEY_ID,
        "TWS_APNS_TEAM_ID": TEAM_ID,
        "TWS_APNS_KEY_PATH": str(legacy),
        "TWS_FCM_SERVICE_ACCOUNT_JSON": _fcm(),
    }
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials(env, tmp_path)
    message = str(raised.value)
    assert "TWS_APNS_KEY" in raised.value.missing
    assert "deprecated" in message
    assert "override" in message
    _assert_no_secret(message)


def test_override_uses_operator_files_and_still_fails_when_missing(tmp_path: Path) -> None:
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials({"TWS_PUSH_CREDENTIAL_SOURCE": "lab"}, tmp_path)
    assert raised.value.source == "override"
    assert "Delivery is not configured" in str(raised.value)
    _assert_no_secret(str(raised.value))

    legacy = CFG.legacy_apns_path(tmp_path)
    fcm = CFG.legacy_fcm_path(tmp_path)
    legacy.parent.mkdir(parents=True)
    fcm.parent.mkdir(parents=True)
    legacy.write_text(_pem(), encoding="utf-8")
    fcm.write_text(_fcm(), encoding="utf-8")
    creds = CFG.load_push_credentials(
        {
            "TWS_PUSH_CREDENTIAL_SOURCE": "override",
            "TWS_APNS_KEY_ID": KEY_ID,
            "TWS_APNS_TEAM_ID": TEAM_ID,
            "TWS_APNS_ENV": "sandbox",
        },
        tmp_path,
    )
    assert creds.source == "override"
    assert creds.apns_keyfile == legacy
    assert creds.fcm_file == fcm
    assert creds.apns_platform == "sandbox"


def test_apply_writes_sygnal_config_without_key_material(tmp_path: Path) -> None:
    doc = CFG.apply_push_config(_base_env(), tmp_path, sygnal_port=5000, write_sygnal=True)
    assert doc["configured"] is True
    assert doc["delivery"] == "sygnal"
    assert doc["source"] == "tinyweb"
    yaml_text = (tmp_path / "sygnal.yaml").read_text(encoding="utf-8")
    assert "type: apns" in yaml_text
    assert "type: gcm" in yaml_text
    assert "api_version: v1" in yaml_text
    assert "platform: production" in yaml_text
    assert f"key_id: {KEY_ID}" in yaml_text
    assert "win.tinyweb.tinyweb.ios" in yaml_text
    assert "win.tinyweb.tinyweb.android" in yaml_text
    _assert_no_secret(yaml_text)
    _assert_no_secret(json.dumps(doc))
    key_file = CFG.default_apns_keyfile(tmp_path)
    fcm_file = CFG.default_fcm_file(tmp_path)
    assert CANARY in key_file.read_text(encoding="utf-8")
    assert CANARY in fcm_file.read_text(encoding="utf-8")
    assert stat.S_IMODE(key_file.stat().st_mode) == 0o640
    assert stat.S_IMODE(fcm_file.stat().st_mode) == 0o640
    status = json.loads((tmp_path / "push" / "credential-status.json").read_text(encoding="utf-8"))
    assert status["configured"] is True
    assert "key_id" not in status.get("apns", {})
    assert "team_id" not in status.get("apns", {})
    assert KEY_ID not in json.dumps(status)
    _assert_no_secret(json.dumps(status))


def test_apply_missing_keys_writes_refused_status_and_empty_apps(tmp_path: Path) -> None:
    env = {"TWS_APNS_KEY": _pem()}
    with pytest.raises(CFG.PushCredentialsError):
        CFG.apply_push_config(env, tmp_path, sygnal_port=5000, write_sygnal=True)
    status = json.loads((tmp_path / "push" / "credential-status.json").read_text(encoding="utf-8"))
    assert status["configured"] is False
    assert status["delivery"] == "refused"
    blob = json.dumps(status)
    assert "Delivery is not configured" in blob
    _assert_no_secret(blob)
    yaml_text = (tmp_path / "sygnal.yaml").read_text(encoding="utf-8")
    assert "apps: {}" in yaml_text
    assert "type: apns" not in yaml_text
    assert not CFG.default_apns_keyfile(tmp_path).exists()
    _assert_no_secret(yaml_text)


def test_rejects_bad_base64_and_project_mismatch_without_values(tmp_path: Path) -> None:
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials(_base_env(TWS_APNS_KEY="", TWS_APNS_KEY_B64=CANARY), tmp_path)
    assert "TWS_APNS_KEY_B64" in raised.value.invalid
    _assert_no_secret(str(raised.value))

    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials(_base_env(TWS_FCM_PROJECT_ID="other-project"), tmp_path)
    assert "TWS_FCM_PROJECT_ID" in raised.value.invalid
    _assert_no_secret(str(raised.value))


def test_unknown_source_is_rejected_and_not_echoed(tmp_path: Path) -> None:
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.apply_push_config(
            {"TWS_PUSH_CREDENTIAL_SOURCE": CANARY},
            tmp_path,
            write_sygnal=True,
        )
    assert CANARY not in str(raised.value)
    assert raised.value.__cause__ is None
    assert "TWS_PUSH_CREDENTIAL_SOURCE" in raised.value.invalid
    status = json.loads((tmp_path / "push" / "credential-status.json").read_text(encoding="utf-8"))
    assert status["configured"] is False
    assert status["delivery"] == "refused"
    assert CANARY not in json.dumps(status)


def test_world_readable_operator_env_is_refused(tmp_path: Path) -> None:
    push = CFG.shared_push_dir(tmp_path)
    push.mkdir(parents=True)
    operator = push / CFG.OPERATOR_ENV_NAME
    operator.write_text(f"TWS_APNS_KEY_ID={KEY_ID}\nTWS_APNS_KEY={_pem()}\n", encoding="utf-8")
    os.chmod(operator, 0o644)
    with pytest.raises(CFG.PushCredentialsError) as raised:
        CFG.load_push_credentials({}, tmp_path)
    assert "world-readable" in str(raised.value)
    _assert_no_secret(str(raised.value))


def test_hook_exits_2_when_keys_missing_and_0_when_configured(tmp_path: Path) -> None:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("TWS_APNS", "TWS_FCM", "TWS_PUSH", "TWS_ANDROID")):
            env.pop(key, None)
    env.update(
        {
            "TWS_ETC_DIR": str(tmp_path),
            "TWS_SYGNAL_PORT": "5000",
            "DRY_RUN": "0",
            "TWS_APNS_KEY": _pem(),
        }
    )
    missing = subprocess.run(
        ["bash", str(HOOK), "--write-sygnal"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert missing.returncode == 2, missing.stderr
    combined = missing.stdout + missing.stderr
    assert "Delivery is not configured" in combined
    assert "TWS_APNS_KEY_ID" in combined
    _assert_no_secret(combined)
    status = json.loads((tmp_path / "push" / "credential-status.json").read_text(encoding="utf-8"))
    assert status["delivery"] == "refused"
    assert "apps: {}" in (tmp_path / "sygnal.yaml").read_text(encoding="utf-8")

    env.update(_base_env())
    ready = subprocess.run(
        ["bash", str(HOOK), "--write-sygnal"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert ready.returncode == 0, ready.stderr
    _assert_no_secret(ready.stdout + ready.stderr)
    yaml_text = (tmp_path / "sygnal.yaml").read_text(encoding="utf-8")
    assert "type: gcm" in yaml_text
    _assert_no_secret(yaml_text)


def test_hook_dry_run_does_not_require_keys(tmp_path: Path) -> None:
    env = {"DRY_RUN": "1", "TWS_ETC_DIR": str(tmp_path), "PATH": os.environ.get("PATH", "/usr/bin")}
    proc = subprocess.run(
        ["bash", str(HOOK), "--write-sygnal"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "DRY_RUN" in proc.stderr
    assert not (tmp_path / "sygnal.yaml").exists()


def test_push_doc_names_williams_secrets_and_ships_no_key_material() -> None:
    text = (ROOT / "docs" / "PUSH.md").read_text(encoding="utf-8")
    for name in (
        "TWS_APNS_KEY",
        "TWS_APNS_KEY_ID",
        "TWS_APNS_TEAM_ID",
        "TWS_FCM_SERVICE_ACCOUNT_JSON",
        "configure-push-credentials.sh",
    ):
        assert name in text
    assert "William" in text
    lowered = text.lower()
    assert "parent" in lowered
    assert "BEGIN PRIVATE KEY" not in text
    assert "AIza" not in text
    example = (ROOT / "config" / "push-operator.env.example").read_text(encoding="utf-8")
    assert "BEGIN PRIVATE KEY" not in example
    assert "TWS_APNS_KEY_ID" in example
