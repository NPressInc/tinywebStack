"""Allow ``python -m tinywebstack_calendar.setup`` / ``verify`` via -m on submodules only."""

from __future__ import annotations

import sys

if __name__ == "__main__":
    print("Use python -m tinywebstack_calendar.setup or python -m tinywebstack_calendar.verify", file=sys.stderr)
    sys.exit(2)
