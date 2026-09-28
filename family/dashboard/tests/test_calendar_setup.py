from tinywebstack_dashboard.calendar_setup import caldav_account_url, davx5_login_hint


def test_caldav_account_url() -> None:
    url = caldav_account_url("https://nc.example/nextcloud/remote.php/dav", "parent")
    assert url.endswith("/principals/users/parent/")


def test_davx5_hint_includes_username() -> None:
    hint = davx5_login_hint("https://nc.example/dav", "kid")
    assert "kid" in hint
    assert "nc.example" in hint
