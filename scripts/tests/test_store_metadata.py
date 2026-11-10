"""Store listing and privacy scaffolding stay consistent and secret-free."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "store" / "check_store_metadata.py"


def _checker():
    spec = importlib.util.spec_from_file_location("check_store_metadata", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_store_metadata_repo_agrees() -> None:
    checker = _checker()
    assert checker.check_repo(ROOT) == []


def test_keywords_reject_the_app_name_and_spaces() -> None:
    checker = _checker()
    assert checker.keyword_errors("TinyWeb,family", "TinyWeb")
    assert checker.keyword_errors("family, home", "TinyWeb")
    assert checker.keyword_errors("family,home", "TinyWeb") == []


def test_length_limit() -> None:
    checker = _checker()
    assert checker.length_error("name.txt", "x" * 31, 30)
    assert checker.length_error("name.txt", "TinyWeb", 30) is None
    assert checker.length_error("name.txt", "  \n", 30)


def test_secret_scan_flags_a_certificate_and_a_keystore_password() -> None:
    checker = _checker()
    header = "-----BEGIN " + "CERTIFICATE-----"
    assert checker.secret_errors("fixture", f"prefix {header} suffix")
    assert checker.secret_errors("fixture", "storePassword=not-a-real-secret")
    assert checker.secret_errors("fixture", "storePassword=\nkeyPassword=\n") == []
