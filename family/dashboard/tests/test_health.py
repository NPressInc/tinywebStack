"""Parent health page: auth, status mapping, and no secret leakage."""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tinywebstack_dashboard.app import DashboardConfig, create_app
from tinywebstack_dashboard.app_devices import create_device, init_db, mint_device_token
from tinywebstack_dashboard.health import (
    CertResult,
    DiskResult,
    HealthCache,
    HealthSnapshot,
    HttpResult,
    UnitSnapshot,
    UnitState,
    fetch_http,
    fetch_units,
    parse_df,
    parse_openssl_enddate,
    parse_systemctl_show,
    public_dict,
    report_from_snapshot,
    run_checked,
    service_urls,
    certificate_hosts,
)

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=timezone.utc)
SECRET = "tws_supersecretvalue"
SECRET_PATH = "/etc/tinywebstack/synapse-admin-token"
LEAK = f"Bearer {SECRET} {SECRET_PATH} token={SECRET}"


def _http(**kwargs) -> HttpResult:
    return HttpResult(**kwargs)


def base_snapshot() -> HealthSnapshot:
    http = {
        "synapse": _http(status_code=200, body='{"versions":["r0.6.0"]}'),
        "calendars": _http(status_code=401, body="Unauthorized"),
        "events": _http(status_code=302, body=""),
        "location": _http(status_code=200, body="[]"),
        "sygnal": _http(status_code=200, body="OK"),
        "ntfy": _http(status_code=200, body='{"healthy":true}'),
        "jellyfin": _http(error="unreachable"),
    }
    units = {
        "synapse": UnitState(installed=True, active=True),
        "mobilizon": UnitState(installed=True, active=True),
        "ot-recorder": UnitState(installed=True, active=True),
        "tinywebstack-sygnal": UnitState(installed=True, active=True),
        "tinywebstack-ntfy": UnitState(installed=True, active=True),
    }
    return HealthSnapshot(
        http=http,
        units=UnitSnapshot(units=units),
        certs=[
            CertResult(
                host="family-a.test",
                reachable=True,
                expires_at=datetime(2027, 6, 1, tzinfo=timezone.utc),
            )
        ],
        disk=DiskResult(total_bytes=64 * 1024**3, avail_bytes=40 * 1024**3),
        optional_files={"jellyfin": False, "backup": False},
        location_backend="owntracks",
        push_enabled=True,
    )


def with_http(snapshot: HealthSnapshot, key: str, result: HttpResult) -> HealthSnapshot:
    http = dict(snapshot.http)
    http[key] = result
    return replace(snapshot, http=http)


def find(checks, check_id: str):
    return next(item for item in checks if item.id == check_id)


def public_blob(snapshot: HealthSnapshot) -> str:
    checks = report_from_snapshot(snapshot, now=NOW)
    return json.dumps(public_dict(checks, cached=False))


class FakeProbes:
    def __init__(self, snapshot: HealthSnapshot, boom: str = "") -> None:
        self.snapshot_value = snapshot
        self.boom = boom
        self.calls = 0

    def snapshot(self, cfg):  # noqa: ARG002
        self.calls += 1
        if self.boom:
            raise RuntimeError(self.boom)
        return self.snapshot_value


@pytest.fixture
def quiet_env(monkeypatch):
    monkeypatch.delenv("TWS_JELLYFIN_URL", raising=False)
    monkeypatch.delenv("LOCATION_APP", raising=False)
    monkeypatch.delenv("TWS_PUSH_ENABLE", raising=False)
    monkeypatch.delenv("TWS_SYNAPSE_HEALTH_URL", raising=False)
    monkeypatch.delenv("TWS_OWNTRACKS_API_URL", raising=False)


def test_ok_fail_and_timeout_for_each_check(quiet_env):
    snap = base_snapshot()
    checks = {item.id: item for item in report_from_snapshot(snap, now=NOW)}
    assert checks["synapse"].status == "ok"
    assert checks["calendars"].status == "ok"
    assert checks["events"].status == "ok"
    assert checks["location"].status == "ok"
    assert checks["push"].status == "ok"
    assert checks["web"].status == "ok"
    assert checks["disk"].status == "ok"
    assert checks["jellyfin"].status == "not_installed"
    assert checks["backups"].status == "not_installed"
    assert "Not installed." in checks["jellyfin"].summary
    assert "error" not in checks["jellyfin"].summary.lower()

    failed = with_http(snap, "synapse", _http(error="unreachable"))
    failed = replace(
        failed,
        units=UnitSnapshot(
            units={
                **snap.units.units,
                "synapse": UnitState(installed=True, active=False),
            }
        ),
    )
    assert find(report_from_snapshot(failed, now=NOW), "synapse").status == "problem"
    assert "switched off" in find(report_from_snapshot(failed, now=NOW), "synapse").summary

    timed = with_http(snap, "synapse", _http(error="timeout"))
    chat = find(report_from_snapshot(timed, now=NOW), "synapse")
    assert chat.status == "problem"
    assert "did not answer in time" in chat.summary

    cal_fail = with_http(snap, "calendars", _http(status_code=500, body=LEAK))
    calendars = find(report_from_snapshot(cal_fail, now=NOW), "calendars")
    assert calendars.status == "problem"
    assert SECRET not in calendars.summary

    cal_time = with_http(snap, "calendars", _http(error="timeout"))
    assert "did not answer in time" in find(report_from_snapshot(cal_time, now=NOW), "calendars").summary

    events_fail = with_http(snap, "events", _http(error="unreachable"))
    events_fail = replace(
        events_fail,
        units=UnitSnapshot(units={**snap.units.units, "mobilizon": UnitState(True, False)}),
    )
    assert find(report_from_snapshot(events_fail, now=NOW), "events").status == "problem"

    events_time = with_http(snap, "events", _http(error="timeout"))
    assert "did not answer in time" in find(report_from_snapshot(events_time, now=NOW), "events").summary

    loc_fail = with_http(snap, "location", _http(error="unreachable"))
    loc_fail = replace(loc_fail, units=UnitSnapshot(units={}))
    assert "not set up" in find(report_from_snapshot(loc_fail, now=NOW), "location").summary

    loc_time = with_http(snap, "location", _http(error="timeout"))
    assert "did not answer in time" in find(report_from_snapshot(loc_time, now=NOW), "location").summary

    push_fail = with_http(snap, "sygnal", _http(error="unreachable"))
    push_fail = replace(
        push_fail,
        units=UnitSnapshot(
            units={
                "tinywebstack-sygnal": UnitState(True, True),
            }
        ),
    )
    assert find(report_from_snapshot(push_fail, now=NOW), "push").status == "problem"

    push_time = with_http(snap, "sygnal", _http(error="timeout"))
    assert "did not answer in time" in find(report_from_snapshot(push_time, now=NOW), "push").summary

    web_time = replace(
        snap,
        certs=[CertResult(host="family-a.test", reachable=False, timed_out=True)],
    )
    web = find(report_from_snapshot(web_time, now=NOW), "web")
    assert web.status == "problem"
    assert "did not answer in time" in web.summary

    disk_time = replace(snap, disk=DiskResult(error="timeout"))
    disk = find(report_from_snapshot(disk_time, now=NOW), "disk")
    assert disk.status == "problem"
    assert "in time" in disk.summary

    jelly_time = replace(
        snap,
        optional_files={"jellyfin": True, "backup": False},
        http={**snap.http, "jellyfin": _http(error="timeout")},
    )
    movies = find(report_from_snapshot(jelly_time, now=NOW), "jellyfin")
    assert movies.status == "problem"
    assert "did not answer in time" in movies.summary

    backup_time = replace(snap, units=UnitSnapshot(timed_out=True))
    backups = find(report_from_snapshot(backup_time, now=NOW), "backups")
    assert backups.status == "warning"
    assert "in time" in backups.summary


def test_warning_mappings(quiet_env):
    snap = base_snapshot()
    soon = replace(
        snap,
        certs=[
            CertResult(
                host="family-a.test",
                reachable=True,
                expires_at=NOW + timedelta(days=10),
            )
        ],
    )
    web = find(report_from_snapshot(soon, now=NOW), "web")
    assert web.status == "warning"
    assert "expires on" in web.summary

    expired = replace(
        snap,
        certs=[
            CertResult(
                host="family-a.test",
                reachable=True,
                expires_at=NOW - timedelta(days=1),
            )
        ],
    )
    assert find(report_from_snapshot(expired, now=NOW), "web").status == "problem"
    assert "expired" in find(report_from_snapshot(expired, now=NOW), "web").summary

    low = replace(snap, disk=DiskResult(total_bytes=64 * 1024**3, avail_bytes=4 * 1024**3))
    assert find(report_from_snapshot(low, now=NOW), "disk").status == "warning"
    full = replace(snap, disk=DiskResult(total_bytes=64 * 1024**3, avail_bytes=512 * 1024**2))
    assert find(report_from_snapshot(full, now=NOW), "disk").status == "problem"

    stub = with_http(snap, "sygnal", _http(status_code=200, body=json.dumps({"status": "ok", "mode": "stub", "note": LEAK})))
    push = find(report_from_snapshot(stub, now=NOW), "push")
    assert push.status == "warning"
    assert "partly set up" in push.summary
    assert SECRET not in push.summary
    assert SECRET_PATH not in push.hint

    odd = with_http(snap, "synapse", _http(status_code=200, body="hello"))
    assert find(report_from_snapshot(odd, now=NOW), "synapse").status == "warning"


def test_optional_services_and_traccar(quiet_env):
    snap = base_snapshot()
    jelly = replace(
        snap,
        optional_files={"jellyfin": True, "backup": False},
        http={**snap.http, "jellyfin": _http(status_code=200, body="Healthy")},
    )
    assert find(report_from_snapshot(jelly, now=NOW), "jellyfin").status == "ok"

    jelly_down = replace(
        snap,
        units=UnitSnapshot(units={**snap.units.units, "jellyfin": UnitState(True, True)}),
        http={**snap.http, "jellyfin": _http(error="unreachable")},
    )
    assert find(report_from_snapshot(jelly_down, now=NOW), "jellyfin").status == "problem"

    running = replace(
        snap,
        units=UnitSnapshot(
            units={**snap.units.units, "tinywebstack-backup.timer": UnitState(True, True)}
        ),
    )
    assert find(report_from_snapshot(running, now=NOW), "backups").status == "ok"

    stopped = replace(
        snap,
        units=UnitSnapshot(
            units={**snap.units.units, "borgmatic.service": UnitState(True, False)}
        ),
    )
    assert find(report_from_snapshot(stopped, now=NOW), "backups").status == "problem"

    settings_only = replace(snap, optional_files={"jellyfin": False, "backup": True})
    assert find(report_from_snapshot(settings_only, now=NOW), "backups").status == "warning"

    traccar = replace(
        snap,
        location_backend="traccar",
        http={**snap.http, "location": _http(status_code=401, body=LEAK)},
    )
    assert find(report_from_snapshot(traccar, now=NOW), "location").status == "ok"
    assert SECRET not in public_blob(traccar)


def test_public_report_hides_secrets_paths_and_loopback(quiet_env):
    snap = with_http(
        base_snapshot(),
        "synapse",
        _http(status_code=200, body='{"versions":["r"], "token":"%s", "path":"%s"}' % (SECRET, SECRET_PATH)),
    )
    snap = replace(
        snap,
        certs=[CertResult(host="family-a.test", reachable=False, timed_out=False)],
        disk=DiskResult(total_bytes=10, avail_bytes=10),
    )
    blob = public_blob(snap)
    assert SECRET not in blob
    assert "synapse-admin-token" not in blob
    assert "/etc/" not in blob
    assert "/var/" not in blob
    assert "127.0.0.1" not in blob
    assert "Bearer" not in blob
    assert "/dev/" not in blob
    payload = json.loads(blob)
    assert set(payload) == {"overall", "checked_at", "cached", "checks"}
    for row in payload["checks"]:
        assert set(row) == {"id", "title", "status", "summary", "hint", "checked_at"}
        assert row["status"] in {"ok", "warning", "problem", "not_installed"}


def test_df_and_systemctl_parsers_drop_device_names():
    parsed = parse_df(
        "Filesystem 1B-blocks Used Available Capacity Mounted on\n"
        "/dev/sda1 1000 100 800 20% /\n"
    )
    assert parsed.total_bytes == 1000
    assert parsed.avail_bytes == 800
    assert SECRET_PATH not in repr(parsed)

    units = parse_systemctl_show(
        "Id=synapse.service\nLoadState=loaded\nActiveState=active\n\n"
        "Id=jellyfin.service\nLoadState=not-found\nActiveState=inactive\n\n"
        "Id=tinywebstack-backup.timer\nLoadState=loaded\nActiveState=active\n"
    )
    assert units["synapse"].installed and units["synapse"].active
    assert units["jellyfin"].installed is False
    assert units["tinywebstack-backup.timer"].active
    assert parse_openssl_enddate("notAfter=Jun  1 00:00:00 2027 GMT") == datetime(
        2027, 6, 1, tzinfo=timezone.utc
    )


def test_systemctl_failure_is_not_treated_as_missing(monkeypatch):
    class Proc:
        returncode = 1
        stdout = b""

    monkeypatch.setattr("tinywebstack_dashboard.health.run_checked", lambda *_a, **_k: Proc())
    snap = fetch_units()
    assert snap.timed_out is True
    assert snap.units == {}


def test_run_checked_rejects_arbitrary_commands():
    with pytest.raises(ValueError):
        run_checked(["bash", "-c", "id"], 1)
    with pytest.raises(ValueError):
        run_checked(["systemctl", "restart", "synapse"], 1)
    with pytest.raises(ValueError):
        run_checked(["systemctl", "show", "-p", "Id", "-p", "LoadState", "-p", "ActiveState", "--", "not-a-unit"], 1)
    with pytest.raises(ValueError):
        run_checked(["df", "-P", "-B1", "/tmp"], 1)
    with pytest.raises(ValueError):
        run_checked(["openssl", "x509", "-in", SECRET_PATH], 1)


def test_fetch_http_timeout_does_not_keep_the_error_text(monkeypatch):
    def boom(*_args, **_kwargs):
        raise TimeoutError(f"timed out reading {SECRET_PATH} {SECRET}")

    monkeypatch.setattr("tinywebstack_dashboard.health.urllib.request.build_opener", lambda *_a, **_k: type("O", (), {"open": staticmethod(boom)})())
    result = fetch_http("http://127.0.0.1:8008/_matrix/client/versions", server_name="family-a.test")
    assert result.error == "timeout"
    assert result.body == ""
    blob = repr(result)
    assert SECRET not in blob
    assert "synapse-admin-token" not in blob


def test_fetch_http_refuses_non_family_and_loopback_tricks(monkeypatch):
    def explode(*_args, **_kwargs):
        raise AssertionError("network should not be used")

    monkeypatch.setattr("tinywebstack_dashboard.health.urllib.request.build_opener", explode)
    assert fetch_http("http://evil.test/health", server_name="family-a.test").error == "unconfigured"
    assert fetch_http("http://127.0.0.1:8008/_matrix/client/versions?token=tws_abc", server_name="family-a.test").error == "unconfigured"
    assert fetch_http("https://user:secret@family-a.test/", server_name="family-a.test").error == "unconfigured"
    assert fetch_http("https://evil.test/health", server_name="family-a.test").error == "unconfigured"
    assert fetch_http("file:///etc/passwd", server_name="family-a.test").error == "unconfigured"


def test_service_urls_stay_on_family_or_loopback(monkeypatch):
    monkeypatch.setenv("TWS_SYNAPSE_HEALTH_URL", "https://evil.test/_matrix/client/versions")
    monkeypatch.setenv("TWS_OWNTRACKS_API_URL", "http://evil.test:25959")
    monkeypatch.setenv("TWS_JELLYFIN_HEALTH_URL", "http://169.254.169.254/latest")
    cfg = DashboardConfig(
        server_name="family-a.test",
        caldav_root="https://nextcloud.family-a.test/remote.php/dav",
        events_base_url="https://user:secret@mobilizon.family-a.test/",
        location_base_url="https://owntracks.family-a.test/",
    )
    urls = service_urls(cfg, location="owntracks", push_on=True)
    assert urls["synapse"] == "http://127.0.0.1:8008/_matrix/client/versions"
    assert urls["location"] == "http://127.0.0.1:25959/api/0/last"
    assert urls["jellyfin"] == "http://127.0.0.1:8096/health"
    assert urls["calendars"] == "https://nextcloud.family-a.test/remote.php/dav"
    assert urls["events"] is None
    hosts = certificate_hosts(cfg, file_exists=lambda _path: False)
    assert "family-a.test" in hosts
    assert "nextcloud.family-a.test" in hosts
    assert "matrix.family-a.test" not in hosts
    assert "evil.test" not in hosts
    assert "secret" not in " ".join(hosts)


def test_cache_serves_a_saved_check_and_limits_refresh():
    calls = {"n": 0}
    clock = {"t": 0.0}

    def loader():
        calls["n"] += 1
        return {"overall": "ok", "checked_at": "2026-11-10T12:00:00Z", "cached": False, "checks": []}

    cache = HealthCache(ttl_s=60, min_refresh_s=15, clock=lambda: clock["t"])
    first = cache.get(loader)
    second = cache.get(loader)
    assert calls["n"] == 1
    assert first["cached"] is False
    assert second["cached"] is True
    assert cache.get(loader, refresh=True)["cached"] is True
    assert calls["n"] == 1
    clock["t"] = 16
    assert cache.get(loader, refresh=True)["cached"] is False
    assert calls["n"] == 2


def _client(tmp_path: Path, monkeypatch, probes: FakeProbes) -> TestClient:
    policy = tmp_path / "family-policy.json"
    policy.write_text(
        json.dumps(
            {
                "server_name": "family-a.test",
                "kids": {"@kid1:family-a.test": {}},
                "parent_mxids": ["@parent1:family-a.test"],
                "trusted_domains": [],
                "reject_encryption": True,
            }
        ),
        encoding="utf-8",
    )
    devices = tmp_path / "app-devices.db"
    monkeypatch.setenv("TWS_APP_DEVICES_DB", str(devices))
    monkeypatch.setenv("TWS_DASHBOARD_MOCK_GROUPS", json.dumps({"parents": ["parent1"], "kids": ["kid1"]}))
    monkeypatch.delenv("TWS_JELLYFIN_URL", raising=False)
    init_db(devices)
    cfg = DashboardConfig(
        policy_path=str(policy),
        server_name="family-a.test",
        csrf_secret="test-secret",
        caldav_root="https://nextcloud.family-a.test/remote.php/dav",
        events_base_url="https://mobilizon.family-a.test/",
        location_base_url="https://owntracks.family-a.test/",
    )
    return TestClient(create_app(cfg, health_probes=probes))


def test_health_routes_are_parent_only(tmp_path, monkeypatch):
    probes = FakeProbes(base_snapshot())
    client = _client(tmp_path, monkeypatch, probes)
    assert client.get("/health").status_code == 401
    assert client.get("/api/health").status_code == 401
    assert client.get("/health", headers={"YNH_USER": "kid1"}).status_code == 403
    assert client.get("/api/health", headers={"YNH_USER": "kid1"}).status_code == 403

    kid = mint_device_token()
    create_device(username="kid1", role="kid", device_name="K", platform="android", token=kid)
    kid_api = client.get("/api/health", headers={"Authorization": f"Bearer {kid}"})
    assert kid_api.status_code == 403

    page = client.get("/health", headers={"YNH_USER": "parent1"})
    assert page.status_code == 200
    assert "Is everything working?" in page.text
    assert "Chat" in page.text
    assert "Not installed" in page.text
    assert SECRET not in page.text
    assert "127.0.0.1" not in page.text
    assert "systemctl" not in page.text
    assert "/etc/" not in page.text

    parent = mint_device_token()
    create_device(username="parent1", role="parent", device_name="P", platform="ios", token=parent)
    api = client.get("/api/health", headers={"Authorization": f"Bearer {parent}"})
    assert api.status_code == 200
    assert api.headers["cache-control"] == "no-store"
    assert api.json()["overall"] == "ok"
    assert probes.calls == 1

    again = client.get("/health", headers={"YNH_USER": "parent1"})
    assert again.status_code == 200
    assert probes.calls == 1

    noisy = client.get("/health?refresh=systemctl%20restart", headers={"YNH_USER": "parent1"})
    assert noisy.status_code == 200
    assert "systemctl" not in noisy.text
    assert "refresh=systemctl" not in noisy.text
    assert probes.calls == 1


def test_probe_crash_does_not_leak_the_exception(tmp_path, monkeypatch):
    probes = FakeProbes(base_snapshot(), boom=f"failed reading {SECRET_PATH} {SECRET}")
    client = _client(tmp_path, monkeypatch, probes)
    page = client.get("/health", headers={"YNH_USER": "parent1"})
    assert page.status_code == 200
    assert SECRET not in page.text
    assert "synapse-admin-token" not in page.text
    assert "could not be checked" in page.text
    api = client.get("/api/health", headers={"YNH_USER": "parent1"})
    blob = json.dumps(api.json())
    assert SECRET not in blob
    assert "/etc/" not in blob


def test_family_home_links_to_health(tmp_path, monkeypatch):
    probes = FakeProbes(base_snapshot())
    client = _client(tmp_path, monkeypatch, probes)
    page = client.get("/", headers={"YNH_USER": "parent1"})
    assert page.status_code == 200
    assert "Open health" in page.text
    assert "/family/health" in page.text
    assert probes.calls == 0
    client.get("/health", headers={"YNH_USER": "parent1"})
    home = client.get("/", headers={"YNH_USER": "parent1"})
    assert "Everything checked is working" in home.text
