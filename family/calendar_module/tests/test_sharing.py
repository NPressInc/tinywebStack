from tinywebstack_calendar.sharing import group_principal, share_request_body, user_principal


def test_principal_hrefs() -> None:
    assert group_principal("parents") == "principal:principals/groups/parents"
    assert user_principal("kid") == "principal:principals/users/kid"


def test_share_request_body_includes_group_href() -> None:
    body = share_request_body(group_principal("federation-test"))
    assert "federation-test" in body
