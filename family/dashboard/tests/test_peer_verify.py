"""Unit tests for peer Matrix server key verification."""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

from tinywebstack_dashboard.peer_verify import (
    fetch_matrix_server_key,
    resolve_matrix_server_endpoint,
    verify_peer_domain,
)


def _mock_response(body: dict) -> MagicMock:
    resp = MagicMock()
    resp.read.return_value = json.dumps(body).encode("utf-8")
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


def test_resolve_matrix_server_endpoint_from_well_known() -> None:
    with patch("tinywebstack_dashboard.peer_verify.urllib.request.urlopen") as urlopen:
        urlopen.return_value = _mock_response({"m.server": "matrix.peer.test:8448"})
        assert resolve_matrix_server_endpoint("peer.test") == "matrix.peer.test:8448"
        urlopen.assert_called_once()
        assert urlopen.call_args[0][0].full_url == "https://peer.test/.well-known/matrix/server"


def test_resolve_matrix_server_endpoint_falls_back_to_peer_domain() -> None:
    with patch(
        "tinywebstack_dashboard.peer_verify.urllib.request.urlopen",
        side_effect=OSError("unreachable"),
    ):
        assert resolve_matrix_server_endpoint("peer.test") == "peer.test"


def test_verify_peer_domain_uses_well_known_server_host() -> None:
    key_doc = {"server_name": "peer.test", "verify_keys": {}}
    with patch("tinywebstack_dashboard.peer_verify.urllib.request.urlopen") as urlopen:
        urlopen.side_effect = [
            _mock_response({"m.server": "matrix.peer.test"}),
            _mock_response(key_doc),
        ]
        out = verify_peer_domain("peer.test", None)
        assert out == key_doc
        assert urlopen.call_args_list[1][0][0].full_url == (
            "https://matrix.peer.test/_matrix/key/v2/server"
        )


def test_verify_peer_domain_explicit_matrix_server_skips_well_known() -> None:
    key_doc = {"server_name": "peer.test", "verify_keys": {}}
    with patch("tinywebstack_dashboard.peer_verify.urllib.request.urlopen") as urlopen:
        urlopen.return_value = _mock_response(key_doc)
        out = verify_peer_domain("peer.test", "matrix.peer.test")
        assert out == key_doc
        urlopen.assert_called_once()
        assert urlopen.call_args[0][0].full_url == (
            "https://matrix.peer.test/_matrix/key/v2/server"
        )


def test_fetch_matrix_server_key_url() -> None:
    key_doc = {"server_name": "peer.test"}
    with patch("tinywebstack_dashboard.peer_verify.urllib.request.urlopen") as urlopen:
        urlopen.return_value = _mock_response(key_doc)
        assert fetch_matrix_server_key("matrix.peer.test") == key_doc
