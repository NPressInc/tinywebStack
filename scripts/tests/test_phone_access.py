"""Static checks for scripts/spark/phone-access.sh (no root required)."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PHONE_ACCESS = ROOT / "scripts" / "spark" / "phone-access.sh"


def test_nat_unit_waits_for_network_tailscale_libvirt_docker() -> None:
    text = PHONE_ACCESS.read_text()
    assert (
        "After=network-online.target tailscaled.service libvirtd.service docker.service"
        in text
    )


def test_nat_up_inserts_libvirt_fwi_accept_rule() -> None:
    text = PHONE_ACCESS.read_text()
    assert "LIBVIRT_FWI" in text
    assert "iptables -I LIBVIRT_FWI" in text
    assert "multiport --dports 80,443" in text
