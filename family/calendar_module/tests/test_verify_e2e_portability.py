"""E2E verifiers must run off-spark: optional lab CA + configurable participant names."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPARK = ROOT / "scripts" / "spark"
LIB = ROOT / "scripts" / "lib"


def _text(name: str) -> str:
    return (SPARK / name).read_text(encoding="utf-8")


def test_secrets_lib_helpers_exist() -> None:
    lib = (LIB / "secrets.sh").read_text(encoding="utf-8")
    for fn in (
        "validate_test_user_name",
        "test_password_env_key",
        "user_test_password",
        "resolve_ca_bundle",
        "require_ca_bundle_or_die",
    ):
        assert f"{fn}()" in lib


def test_verifiers_default_to_system_trust_not_hard_fail() -> None:
    for name in (
        "verify-federation-e2e.sh",
        "verify-calendar-e2e.sh",
        "verify-events-e2e.sh",
    ):
        text = _text(name)
        assert "resolve_ca_bundle" in text
        assert "require_ca_bundle_or_die" in text
        # No lab-CA-path resolution left inline (single helper source of truth).
        assert "resolve_lab_ca" not in text
        assert "Lab CA not found (set TW_STACK_LAB_CA_DIR or run stage-lab-certs.sh)" not in text


def test_federation_verifier_participants_configurable() -> None:
    text = _text("verify-federation-e2e.sh")
    assert "TWS_ALICE_USER:-alice" in text
    assert "TWS_BOB_USER:-bob" in text
    assert "ALICE_USER=${5:-${TWS_ALICE_USER:-alice}}" in text
    assert "BOB_USER=${6:-${TWS_BOB_USER:-bob}}" in text
    assert "user_test_password" in text


def test_calendar_verifier_participants_configurable() -> None:
    text = _text("verify-calendar-e2e.sh")
    # Participants resolve through family_users.sh (owner/first-kid), with the
    # TWS_PARENT_USER / TWS_KID_USER env and positional args as explicit overrides.
    assert "resolve_family_users" in text
    assert "resolve_family_owner" in text
    assert "resolve_family_kids" in text
    assert "TWS_PARENT_USER" in text
    assert "TWS_KID_USER" in text
    assert '--user "$PARENT_USER"' in text
    assert '--attendee-user "$KID_USER"' in text


def test_events_verifier_participant_configurable_and_no_insecure_tls() -> None:
    text = _text("verify-events-e2e.sh")
    assert "TWS_PARENT_USER" in text
    # Default falls back through TWS_PARENT_USER to the family_users.sh organizer.
    assert "PARENT_USER=${6:-${TWS_PARENT_USER:-$(resolve_family_owner" in text
    # System-trust fallback must never disable verification.
    assert "CERT_NONE" not in text
    assert "check_hostname = False" not in text


def test_vm_scripts_use_configurable_users() -> None:
    cal = (ROOT / "scripts" / "vm" / "setup-family-calendars.sh").read_text(encoding="utf-8")
    assert '--users "$CALENDAR_USERS"' in cal
    assert "--owner parent" not in cal
    # The vm scripts resolve the member list exclusively through family_users.sh;
    # the old TWS_CALENDAR_USERS/owner duplicate mechanism is retired.
    assert "resolve_family_users" in cal
    assert "TWS_CALENDAR_USERS" not in cal
    fam = (ROOT / "scripts" / "vm" / "create-family-test-users.sh").read_text(encoding="utf-8")
    assert 'create_user "$user"' in fam
    assert "create_user parent " not in fam
    assert "resolve_family_users" in fam
    assert "TWS_CALENDAR_USERS" not in fam


def test_defaults_env_documents_overrides() -> None:
    defaults = (ROOT / "config" / "defaults.env").read_text(encoding="utf-8")
    for var in (
        "TWS_FAMILY_USERS",
        "TWS_ALICE_USER",
        "TWS_BOB_USER",
        "TWS_PARENT_USER",
        "TWS_KID_USER",
        "TWS_REQUIRE_LAB_CA",
    ):
        assert var in defaults
    # Retired duplicate mechanism: no TWS_CALENDAR_USERS left anywhere.
    assert "TWS_CALENDAR_USERS" not in defaults
