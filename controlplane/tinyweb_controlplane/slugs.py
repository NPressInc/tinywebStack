"""Family slug rules. A slug is one DNS label under the base domain."""

from __future__ import annotations

import re

from tinyweb_controlplane.errors import ApiError

# Same shape as scripts/lib/tinyweb-install-env.sh resolve_tws_domain, lowercase.
SLUG_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

# Labels that would collide with zone infrastructure, not with a family name.
RESERVED_SLUGS = frozenset(
    {
        "www",
        "mail",
        "smtp",
        "imap",
        "pop",
        "autoconfig",
        "autodiscover",
        "ns",
        "ns1",
        "ns2",
        "dns",
        "ftp",
        "localhost",
        "wildcard",
        "wpad",
        "mta-sts",
        "openid",
        "cloudflare",
    }
)


def normalize_slug(raw: str) -> str:
    return raw.strip().lower()


def validate_slug(raw: str) -> str:
    slug = normalize_slug(raw)
    if not slug or not SLUG_RE.fullmatch(slug):
        raise ApiError(
            400,
            "invalid_slug",
            "Family name must be a single DNS label: letters, digits, and hyphens, not a full domain.",
        )
    if slug in RESERVED_SLUGS:
        raise ApiError(400, "reserved_slug", f"{slug} is reserved and cannot be a family name.")
    return slug


def family_domain(slug: str, base_domain: str) -> str:
    return f"{slug}.{base_domain}"
