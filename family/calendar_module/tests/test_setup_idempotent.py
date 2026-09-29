from tinywebstack_calendar.setup import _is_duplicate_calendar_error


def test_duplicate_calendar_sql_error_detected() -> None:
    err = RuntimeError(
        "occ dav:create-calendar parent tws-family failed: SQLSTATE[23000]: "
        "1062 Duplicate entry 'principals/users/parent-tws-family'"
    )
    assert _is_duplicate_calendar_error(err)
