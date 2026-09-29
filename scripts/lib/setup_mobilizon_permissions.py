#!/usr/bin/env python3
"""Mobilizon SSO + federation permissions (YunoHost 12 API)."""

from __future__ import annotations

import argparse
import sys

# Federation and discovery must stay reachable without portal SSO (ActivityPub).
FEDERATION_URLS = [
    "/.well-known/webfinger",
    "/.well-known/host-meta",
    "/.well-known/nodeinfo",
    "/.well-known/nodeinfo/2.0",
    "/.well-known/nodeinfo/2.0.json",
    "/api",
    "/api/v1/users",
    "/api/v1/instance",
    "/relay",
    "/inbox",
    "/users",
]


def ensure_permission(
    name: str,
    *,
    url: str,
    allowed: list[str],
    auth_header: bool,
    show_tile: bool,
    protected: bool,
    additional_urls: list[str] | None = None,
) -> None:
    from yunohost.permission import permission_create, permission_url, user_permission_list

    perms = user_permission_list(full=False)["permissions"]
    extra = additional_urls or []
    if name not in perms:
        permission_create(
            name,
            url=url,
            allowed=allowed,
            auth_header=auth_header,
            show_tile=show_tile,
            protected=protected,
            additional_urls=extra,
        )
        return
    permission_url(
        name,
        url=url,
        set_url=extra if extra else None,
        auth_header=auth_header,
    )


def setup_mobilizon_family_permissions(
    *,
    parents_group: str,
    federation_test_group: str,
    admin_user: str,
) -> None:
    ensure_permission(
        "mobilizon.federation",
        url=FEDERATION_URLS[0],
        allowed=["visitors"],
        auth_header=False,
        show_tile=False,
        protected=True,
        additional_urls=FEDERATION_URLS[1:],
    )
    # UI + GraphQL: LDAP login uses Authorization Bearer; must not inject Basic auth.
    ensure_permission(
        "mobilizon.main",
        url="/",
        allowed=[parents_group, federation_test_group, admin_user],
        auth_header=False,
        show_tile=True,
        protected=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parents-group", default="parents")
    parser.add_argument("--federation-test-group", default="federation-test")
    parser.add_argument("--admin-user", default="twsowner")
    args = parser.parse_args()
    setup_mobilizon_family_permissions(
        parents_group=args.parents_group,
        federation_test_group=args.federation_test_group,
        admin_user=args.admin_user,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
