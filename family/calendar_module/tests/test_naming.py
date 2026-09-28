from tinywebstack_calendar.naming import (
    CALENDAR_IDS,
    caldav_root,
    family_group_name,
    nextcloud_domain,
    principal_calendar_url,
)


def test_family_group_from_node_name() -> None:
    assert family_group_name("family-a.family.test", "family-a") == "family-family-a"


def test_nextcloud_domain_and_caldav() -> None:
    main = "family-a.family.test"
    assert nextcloud_domain(main) == "nextcloud.family-a.family.test"
    assert caldav_root(main).endswith("/remote.php/dav")
    url = principal_calendar_url(main, "parent", CALENDAR_IDS["family"])
    assert "/calendars/parent/tws-family/" in url
