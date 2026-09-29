from tinywebstack_calendar.setup import parse_calendar_ids_from_occ_output


def test_parse_bullet_list_calendars() -> None:
    out = """
User parent has the following calendars:
  - tws-family (Family)
  - tws-parents (Parents)
"""
    assert parse_calendar_ids_from_occ_output(out) == ["tws-family", "tws-parents"]


def test_parse_table_calendars() -> None:
    out = """
+-------------+----------------------------------+
| Name        | URI                              |
+-------------+----------------------------------+
| tws-family  | principals/users/parent/calendars/tws-family |
| personal-kid| principals/users/kid/calendars/personal-kid |
+-------------+----------------------------------+
"""
    assert parse_calendar_ids_from_occ_output(out) == ["tws-family", "personal-kid"]
