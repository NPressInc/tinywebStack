import pytest
from unittest.mock import MagicMock

from tinywebstack_family.mobilizon import (
    FederationSyncResult,
    events_domain,
    is_trusted_relay,
    kid_events_enabled,
    kid_usernames_with_events,
    peer_events_hosts,
    relay_address_from_follower,
    sync_instance_federation,
    verify_passive_untrusted_probe,
)


def test_events_domain():
    assert events_domain("family-a.test") == "mobilizon.family-a.test"


def test_peer_events_hosts():
    assert peer_events_hosts(["family-b.test"]) == ["mobilizon.family-b.test"]


def test_relay_address_from_follower_prefers_domain_over_relay_username():
    follower = {
        "actor": {
            "preferredUsername": "relay",
            "domain": "mobilizon.family-b.test",
        }
    }
    assert relay_address_from_follower(follower) == "mobilizon.family-b.test"


def test_relay_address_from_follower_legacy():
    follower = {"actor": {"preferredUsername": "mobilizon.peer.test"}}
    assert relay_address_from_follower(follower) == "mobilizon.peer.test"


def test_is_trusted_relay():
    local = "mobilizon.family-a.test"
    trusted = {"mobilizon.family-b.test"}
    assert is_trusted_relay("mobilizon.family-b.test", trusted, local)
    assert not is_trusted_relay("mobilizon.fr", trusted, local)


def test_kid_events_enabled_default():
    assert kid_events_enabled({}) is True
    assert kid_events_enabled({"events_enabled": False}) is False


def test_kid_usernames_with_events():
    policy = {
        "kids": {
            "@kid1:family-a.test": {"events_enabled": True},
            "@kid2:family-a.test": {"events_enabled": False},
        }
    }
    assert kid_usernames_with_events(policy) == {"kid1"}


def test_federation_sync_surfaces_add_instance_errors():
    client = MagicMock()
    client.instance_followed_status.return_value = "NONE"
    client.add_instance.side_effect = [RuntimeError("Unable to find an instance"), None]
    client.list_relay_followers.return_value = []
    result = sync_instance_federation(
        client,
        local_main_domain="family-a.test",
        trusted_main_domains=["family-b.test"],
    )
    assert "mobilizon.family-b.test" in result.outgoing_errors
    with pytest.raises(RuntimeError):
        result.raise_on_errors()


def test_federation_sync_treats_already_following_as_ok():
    client = MagicMock()
    client.instance_followed_status.return_value = "NONE"
    client.add_instance.side_effect = RuntimeError("You are already following this instance")
    client.list_relay_followers.return_value = []
    result = sync_instance_federation(
        client,
        local_main_domain="family-a.test",
        trusted_main_domains=["family-b.test"],
    )
    assert "mobilizon.family-b.test" in result.outgoing_ok
    result.raise_on_errors()


def test_federation_sync_skips_add_when_already_approved():
    client = MagicMock()
    client.instance_followed_status.return_value = "APPROVED"
    client.list_relay_followers.return_value = []
    result = sync_instance_federation(
        client,
        local_main_domain="family-a.test",
        trusted_main_domains=["family-b.test"],
    )
    client.add_instance.assert_not_called()
    assert "mobilizon.family-b.test" in result.outgoing_ok


def test_passive_probe_does_not_call_add_instance():
    client = MagicMock()
    client.instance_followed_status.return_value = "NONE"
    out = verify_passive_untrusted_probe(client, "mobilizon.fr")
    assert out["must_not_follow"] is False
    client.add_instance.assert_not_called()


def test_passive_probe_flags_pending_follow():
    client = MagicMock()
    client.instance_followed_status.return_value = "PENDING"
    out = verify_passive_untrusted_probe(client, "mobilizon.fr")
    assert out["must_not_follow"] is True


def test_passive_probe_treats_missing_instance_as_pass():
    client = MagicMock()
    client.instance_followed_status.return_value = "NONE"
    out = verify_passive_untrusted_probe(client, "unknown.example")
    assert out["must_not_follow"] is False
