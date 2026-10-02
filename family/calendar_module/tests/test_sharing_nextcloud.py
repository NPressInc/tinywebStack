from unittest import mock

import pytest

from tinywebstack_calendar.sharing import (
    OC_NS,
    list_calendar_sharees,
    share_calendar_with_principal,
    share_request_body,
)


def test_share_body_uses_owncloud_namespace() -> None:
    body = share_request_body("principal:principals/groups/parents", access="read-write")
    assert OC_NS in body
    assert "calendarserver.org" not in body
    assert "oc:read-write" in body


def test_share_skips_when_principal_already_present() -> None:
    with mock.patch(
        "tinywebstack_calendar.sharing.list_calendar_sharees",
        return_value={"principal:principals/groups/parents"},
    ):
        created = share_calendar_with_principal(
            "https://nc.example/dav/calendars/parent/tws-family/",
            "parent",
            "secret",
            "principal:principals/groups/parents",
            skip_if_shared=True,
        )
    assert created is False


def test_open_caldav_raises_on_redirect(monkeypatch: pytest.MonkeyPatch) -> None:
    import urllib.error

    from tinywebstack_calendar.sharing import _open_caldav

    def fake_open(*_args, **_kwargs):
        raise urllib.error.HTTPError(
            url="https://nc.example/dav/",
            code=302,
            msg="Found",
            hdrs={"Location": "https://nc.example/yunohost/sso/"},
            fp=None,
        )

    monkeypatch.setattr("urllib.request.OpenerDirector.open", fake_open)
    with pytest.raises(RuntimeError, match="redirect"):
        _open_caldav(
            "https://nc.example/dav/calendars/parent/tws-family/",
            method="PROPFIND",
            username="parent",
            password="secret",
            body=b"",
            headers={"Depth": "0"},
        )


def test_list_sharees_parses_oc_invite_hrefs() -> None:
    xml = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:propstat>
      <d:prop>
        <oc:invite>
          <oc:sharee>
            <d:href>principal:principals/groups/parents</d:href>
          </oc:sharee>
        </oc:invite>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>"""

    with mock.patch("tinywebstack_calendar.sharing._open_caldav", return_value=(207, xml, {})):
        sharees = list_calendar_sharees("https://nc.example/cal/", "parent", "secret")
    assert sharees == {"principal:principals/groups/parents"}


def test_list_sharees_propfind_404_returns_empty() -> None:
    with mock.patch(
        "tinywebstack_calendar.sharing._open_caldav",
        side_effect=RuntimeError("CalDAV request failed (404): not found"),
    ):
        assert list_calendar_sharees("https://nc.example/cal/", "parent", "secret") == set()
