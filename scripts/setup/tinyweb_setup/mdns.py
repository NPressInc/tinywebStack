"""mDNS announcement and LAN beacon for the setup service.

Packets carry the service type, port, and LAN address. They do not carry a
setup code or a password.
"""

from __future__ import annotations

import json
import socket
import struct
import threading
import time

MDNS_GROUP = "224.0.0.251"
MDNS_PORT = 5353
BEACON_PORT = 4735
SERVICE_TYPE = "_tinyweb-setup._tcp.local"
INSTANCE_NAME = "TinyWeb._tinyweb-setup._tcp.local"
HOST_NAME = "tinyweb.local"

_A = 1
_PTR = 12
_TXT = 16
_SRV = 33


def encode_name(name: str) -> bytes:
    out = bytearray()
    for label in name.rstrip(".").split("."):
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise ValueError(f"bad DNS label in {name}")
        out.append(len(raw))
        out.extend(raw)
    out.append(0)
    return bytes(out)


def _record(name: str, rtype: int, rdata: bytes, ttl: int = 120) -> bytes:
    return encode_name(name) + struct.pack("!HHIH", rtype, 0x8001, ttl, len(rdata)) + rdata


def _txt(parts: list[str]) -> bytes:
    out = bytearray()
    for part in parts:
        raw = part.encode("ascii")
        if len(raw) > 255:
            raise ValueError("TXT string too long")
        out.append(len(raw))
        out.extend(raw)
    return bytes(out)


def build_announcement(port: int, ipv4: str) -> bytes:
    """Unsolicited mDNS response for the setup service."""
    ptr = _record(SERVICE_TYPE, _PTR, encode_name(INSTANCE_NAME))
    srv = _record(
        INSTANCE_NAME,
        _SRV,
        struct.pack("!HHH", 0, 0, port) + encode_name(HOST_NAME),
    )
    txt = _record(INSTANCE_NAME, _TXT, _txt(["path=/v1/setup", "ver=1"]))
    arec = _record(HOST_NAME, _A, socket.inet_aton(ipv4))
    header = struct.pack("!HHHHHH", 0, 0x8400, 0, 4, 0, 0)
    return header + ptr + srv + txt + arec


def packet_is_query_for_us(packet: bytes) -> bool:
    return encode_name(SERVICE_TYPE) in packet or encode_name(INSTANCE_NAME) in packet


def beacon_packet(port: int) -> bytes:
    payload = {
        "v": 1,
        "service": "tinyweb-setup",
        "port": port,
        "host": HOST_NAME,
    }
    return json.dumps(payload, separators=(",", ":")).encode("ascii")


class Announcer:
    """Best-effort mDNS replies plus a UDP beacon. Safe to fail open."""

    def __init__(self, http_port: int, ipv4: str) -> None:
        self.http_port = http_port
        self.ipv4 = ipv4
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="tinyweb-setup-mdns", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)

    def _try_listen(self) -> socket.socket | None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sock.bind(("0.0.0.0", MDNS_PORT))
            group = struct.pack("=4s4s", socket.inet_aton(MDNS_GROUP), socket.inet_aton(self.ipv4))
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, group)
            except OSError:
                pass
            return sock
        except OSError:
            sock.close()
            return None

    def _run(self) -> None:
        packet = build_announcement(self.http_port, self.ipv4)
        beacon = beacon_packet(self.http_port)
        send = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            send.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            listen = self._try_listen()
            try:
                while not self._stop.is_set():
                    try:
                        send.sendto(packet, (MDNS_GROUP, MDNS_PORT))
                        send.sendto(beacon, ("255.255.255.255", BEACON_PORT))
                    except OSError:
                        pass
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline and not self._stop.is_set():
                        if listen is None:
                            self._stop.wait(0.2)
                            continue
                        listen.settimeout(0.2)
                        try:
                            data, addr = listen.recvfrom(2048)
                        except socket.timeout:
                            continue
                        except OSError:
                            break
                        if packet_is_query_for_us(data):
                            try:
                                listen.sendto(packet, addr)
                            except OSError:
                                pass
            finally:
                if listen is not None:
                    listen.close()
        finally:
            send.close()
