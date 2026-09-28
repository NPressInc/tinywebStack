"""dashboard.env parsing and Synapse local-password isolation."""

from pathlib import Path

from tinywebstack_family.dashboard_env import (
    parse_env_file,
    random_synapse_local_password,
    synapse_admin_user_body,
)


def test_parse_env_file_quoted_values_with_spaces(tmp_path: Path) -> None:
    env = tmp_path / "dashboard.env"
    env.write_text(
        "\n".join(
            [
                "TWS_SERVER_NAME=family-a.test",
                'TWS_YUNOHOST_PRIV_HELPER="sudo /usr/local/sbin/tws-family-dashboard-privileged"',
                'TWS_FEDERATION_SYNC_CMD="sudo /usr/local/sbin/tws-family-sync-federation family-a.test"',
            ]
        ),
        encoding="utf-8",
    )
    data = parse_env_file(env)
    assert data["TWS_SERVER_NAME"] == "family-a.test"
    assert data["TWS_YUNOHOST_PRIV_HELPER"] == (
        "sudo /usr/local/sbin/tws-family-dashboard-privileged"
    )
    assert "family-a.test" in data["TWS_FEDERATION_SYNC_CMD"]


def test_synapse_local_password_differs_from_yunohost_password() -> None:
    yunohost_pw = "SamePassword123"
    body = synapse_admin_user_body(yunohost_password=yunohost_pw)
    assert body["deactivated"] is False
    assert body["password"] != yunohost_pw
    assert len(str(body["password"])) >= 16


def test_random_synapse_local_password_is_not_constant() -> None:
    a = random_synapse_local_password()
    b = random_synapse_local_password()
    assert a != b
