"""Family slug check and reservation."""

from __future__ import annotations

import threading

from tinyweb_controlplane.app import create_app
from tinyweb_controlplane.config import Settings
from tinyweb_controlplane.errors import ApiError
from tinyweb_controlplane.providers import FakeProvider
from tinyweb_controlplane.service import Service
from tinyweb_controlplane.store import Store

from support import claim, mint


def test_check_does_not_reserve_and_claim_does(world) -> None:
    first = world.client.get("/v1/slugs/smith")
    second = world.client.get("/v1/slugs/Smith")
    assert first.status_code == 200
    assert first.json() == {
        "slug": "smith",
        "domain": "smith.tinyweb.win",
        "available": True,
        "reason": None,
        "detail": None,
    }
    assert second.json()["available"] is True

    unit = mint(world)
    taken = claim(world, unit["setup_code"], "Smith")
    assert taken.status_code == 200, taken.text
    body = taken.json()
    assert body["slug"] == "smith"
    assert body["domain"] == "smith.tinyweb.win"
    assert body["replayed"] is False

    again = world.client.get("/v1/slugs/smith")
    assert again.json()["available"] is False
    assert again.json()["reason"] == "slug_taken"


def test_invalid_and_reserved_labels_are_rejected(world) -> None:
    invalid = world.client.get("/v1/slugs/smith.tinyweb.win")
    assert invalid.json()["available"] is False
    assert invalid.json()["reason"] == "invalid_slug"
    reserved = world.client.get("/v1/slugs/www")
    assert reserved.json()["reason"] == "reserved_slug"

    unit = mint(world)
    rejected = claim(world, unit["setup_code"], "www")
    assert rejected.status_code == 400
    assert rejected.json()["error"] == "reserved_slug"
    hyphen = claim(world, unit["setup_code"], "-smith")
    assert hyphen.status_code == 400
    assert hyphen.json()["error"] == "invalid_slug"


def test_second_box_cannot_reserve_the_same_slug(world) -> None:
    first = mint(world)
    second = mint(world)
    assert claim(world, first["setup_code"], "smith").status_code == 200
    conflict = claim(world, second["setup_code"], "smith")
    assert conflict.status_code == 409
    assert conflict.json()["error"] == "slug_taken"
    assert world.client.get("/v1/slugs/smith").json()["available"] is False


def test_only_one_parallel_claim_reserves_the_slug(tmp_path) -> None:
    db = tmp_path / "cp.sqlite"
    settings = Settings(
        db_path=str(db),
        operator_token="operator-test-token",
        provider_name="fake",
        base_domain="tinyweb.win",
    )
    service_a = Service(settings, Store(db), FakeProvider())
    service_b = Service(settings, Store(db), FakeProvider())
    code_a = service_a.mint_unit()["setup_code"]
    code_b = service_b.mint_unit()["setup_code"]
    barrier = threading.Barrier(2)
    results: list[tuple] = []
    lock = threading.Lock()

    def reserve(service: Service, code: str) -> None:
        barrier.wait()
        try:
            body = service.claim(code, "smith")
            with lock:
                results.append(("ok", body["unit_id"]))
        except ApiError as exc:
            with lock:
                results.append((exc.code,))

    threads = [
        threading.Thread(target=reserve, args=(service_a, code_a)),
        threading.Thread(target=reserve, args=(service_b, code_b)),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert sorted(item[0] for item in results) == ["ok", "slug_taken"]
    assert service_a.check_slug("smith")["available"] is False
