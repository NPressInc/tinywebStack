#!/usr/bin/env python3
"""Create/update family dashboard SSO permissions on YunoHost 12 (Synapse app subperms)."""

from __future__ import annotations

import argparse
import sys


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


def setup_family_dashboard_permissions(
    synapse_app: str,
    parents_group: str,
    *,
    create_owntracks_pub: bool = True,
) -> None:
    dash = f"{synapse_app}.family_dashboard"
    pub = f"{synapse_app}.family_public"
    ensure_permission(
        dash,
        url="/family",
        allowed=[parents_group],
        auth_header=True,
        show_tile=True,
        protected=True,
    )
    ensure_permission(
        pub,
        url="/family/api/invite/verify",
        allowed=["visitors"],
        auth_header=False,
        show_tile=False,
        protected=True,
        additional_urls=["/.well-known/tinywebstack-family.json"],
    )
    if create_owntracks_pub:
        try:
            ensure_permission(
                "owntracks.pub",
                url="/recorder/pub",
                allowed=["visitors"],
                auth_header=False,
                show_tile=False,
                protected=True,
            )
        except Exception as exc:
            print(f"WARN: owntracks.pub permission skipped: {exc}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--synapse-app", default="synapse")
    parser.add_argument("--parents-group", default="parents")
    parser.add_argument("--skip-owntracks-pub", action="store_true")
    args = parser.parse_args()
    setup_family_dashboard_permissions(
        args.synapse_app,
        args.parents_group,
        create_owntracks_pub=not args.skip_owntracks_pub,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
