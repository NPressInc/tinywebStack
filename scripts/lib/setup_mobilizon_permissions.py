#!/usr/bin/env python3
"""Mobilizon SSO + federation permissions (YunoHost 12 API)."""

from __future__ import annotations

import argparse
import subprocess
import sys

# Public ActivityPub + human-readable event/profile pages (William decision: accept public URLs).
FEDERATION_URLS = [
    "/.well-known/webfinger",
    "/.well-known/host-meta",
    "/.well-known/nodeinfo",
    "/.well-known/nodeinfo/2.0",
    "/.well-known/nodeinfo/2.1",
    "/api",
    "/api/v1/users",
    "/api/v1/instance",
    "/relay",
    "/inbox",
    "/users",
    "/@",
    "/events",
    "/comments",
    "/member",
    "/resource",
    "/accept",
    "/reject",
    "/join",
    "/leave",
    "/tombstones",
    "/groups",
    "/pages",
    "/share",
    "/tags",
    "/media",
    "/proxy",
]


def _init_yunohost() -> None:
    import yunohost

    yunohost.init(interface="cli")


def _permission_allowed(perm: str) -> set[str]:
    from yunohost.permission import user_permission_list

    perms = user_permission_list(full=True).get("permissions") or {}
    meta = perms.get(perm) or {}
    allowed = meta.get("allowed") or []
    return {str(x) for x in allowed}


def reconcile_permission(
    name: str,
    *,
    url: str,
    allowed: list[str],
    auth_header: bool,
    show_tile: bool,
    protected: bool,
    additional_urls: list[str] | None = None,
) -> None:
    from yunohost.permission import permission_create, permission_url, user_permission_update

    extra = additional_urls or []
    from yunohost.permission import user_permission_list

    existing = user_permission_list(full=False).get("permissions") or {}
    if name not in existing:
        permission_create(
            name,
            url=url,
            allowed=allowed,
            auth_header=auth_header,
            show_tile=show_tile,
            protected=protected,
            additional_urls=extra,
        )
    else:
        permission_url(
            name,
            url=url,
            set_url=extra if extra else None,
            auth_header=auth_header,
        )
        current = _permission_allowed(name)
        want = set(allowed)
        user_permission_update(
            name,
            add=sorted(want - current) or None,
            remove=sorted(current - want) or None,
            auth_header=auth_header,
            show_tile=show_tile,
        )


def setup_mobilizon_family_permissions(
    *,
    parents_group: str,
    federation_test_group: str,
    admin_user: str,
) -> None:
    reconcile_permission(
        "mobilizon.federation",
        url=FEDERATION_URLS[0],
        allowed=["visitors"],
        auth_header=False,
        show_tile=False,
        protected=True,
        additional_urls=FEDERATION_URLS[1:],
    )
    reconcile_permission(
        "mobilizon.main",
        url="/",
        allowed=[parents_group, federation_test_group, admin_user],
        auth_header=False,
        show_tile=True,
        protected=True,
    )
    # SSOwat tile flag is easy to miss via API alone; CLI enforces False/True casing.
    subprocess.run(
        [
            "yunohost",
            "user",
            "permission",
            "update",
            "mobilizon.federation",
            "--show_tile",
            "False",
            "--auth_header",
            "False",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parents-group", default="parents")
    parser.add_argument("--federation-test-group", default="federation-test")
    parser.add_argument("--admin-user", default="twsowner")
    args = parser.parse_args()
    try:
        _init_yunohost()
        setup_mobilizon_family_permissions(
            parents_group=args.parents_group,
            federation_test_group=args.federation_test_group,
            admin_user=args.admin_user,
        )
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or exc.stdout or exc, file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — fail loudly for family-init
        print(f"Mobilizon permission setup failed: {exc}", file=sys.stderr)
        return 1

    fed = _permission_allowed("mobilizon.federation")
    if "visitors" not in fed:
        print(f"mobilizon.federation allowed={sorted(fed)} missing visitors", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
