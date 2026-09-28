from tinywebstack_calendar.sharing import group_principal, user_principal


def test_principal_hrefs() -> None:
    assert group_principal("parents") == "principal:principals/groups/parents"
    assert user_principal("kid") == "principal:principals/users/kid"
