#!/usr/bin/env python3
"""First-boot setup service. Listens only while this box is unprovisioned."""

from __future__ import annotations

import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from tinyweb_setup.service import main

if __name__ == "__main__":
    raise SystemExit(main())
