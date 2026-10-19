"""Recorder HTTP API client: query format and response shape (as served by ot-recorder 0.9)."""

import re

from tinywebstack_dashboard import owntracks_recorder as rec


def test_fetch_track_uses_iso_times_and_unwraps_data(monkeypatch):
    seen = {}

    def fake_get_json(path, query=None):
        seen["path"] = path
        seen["query"] = query
        return {"count": 2, "data": [{"lat": 1.0, "lon": 2.0, "tst": 10}, {"lat": 3.0, "lon": 4.0, "tst": 20}]}

    monkeypatch.setattr(rec, "_get_json", fake_get_json)
    rows, ok = rec.fetch_track("kid", "kid-phone", 24)
    assert ok is True
    assert [r["tst"] for r in rows] == [10, 20]
    assert seen["path"] == "/api/0/locations"
    iso = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$")
    assert iso.match(seen["query"]["from"]) and iso.match(seen["query"]["to"])
    assert seen["query"]["user"] == "kid" and seen["query"]["device"] == "kid-phone"


def test_fetch_track_caps_points(monkeypatch):
    monkeypatch.setattr(
        rec, "_get_json", lambda path, query=None: {"count": 5000, "data": [{"tst": i} for i in range(5000)]}
    )
    rows, ok = rec.fetch_track("kid", "kid-phone", 1)
    assert ok and len(rows) == rec.TRACK_POINT_CAP


def test_fetch_track_bad_shape_is_unavailable(monkeypatch):
    monkeypatch.setattr(rec, "_get_json", lambda path, query=None: {"data": "nope"})
    rows, ok = rec.fetch_track("kid", "kid-phone", 1)
    assert rows is None and ok is False
