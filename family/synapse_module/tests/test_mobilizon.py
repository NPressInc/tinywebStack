from tinywebstack_family.mobilizon import (
    events_domain,
    is_trusted_relay,
    kid_events_enabled,
    kid_usernames_with_events,
    peer_events_hosts,
    relay_address_from_follower,
)


def test_events_domain():
    assert events_domain("family-a.test") == "mobilizon.family-a.test"


def test_peer_events_hosts():
    assert peer_events_hosts(["family-b.test"]) == ["mobilizon.family-b.test"]


def test_relay_address_from_follower():
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
