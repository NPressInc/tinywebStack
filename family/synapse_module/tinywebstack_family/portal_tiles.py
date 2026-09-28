"""YunoHost 12 portal tile CLI values (case-sensitive)."""

from __future__ import annotations


def show_tile_cli_value(*, visible: bool) -> str:
    """Return ``True`` or ``False`` as required by ``yunohost user permission update -s/--show_tile``."""
    return "True" if visible else "False"
