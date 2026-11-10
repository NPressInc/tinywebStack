"""HTTP helpers for control-plane tests."""

from __future__ import annotations


def mint(world) -> dict:
    response = world.client.post(
        "/v1/operator/units",
        headers={"Authorization": "Bearer operator-test-token"},
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["setup_url"].startswith("https://tinyweb.win/setup#code=")
    assert body["setup_app_url"].startswith("tinyweb://setup#code=")
    assert "setup_code" not in body["setup_url"].split("#", 1)[0]
    return body


def claim(world, setup_code: str, slug: str = "smith"):
    return world.client.post("/v1/setup/claim", json={"setup_code": setup_code, "slug": slug})
