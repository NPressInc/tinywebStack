"""CLI for the family permissions DB: seed / import / export / show / set.

Usage (on the node, as root):
  tws-permissions seed [--db PATH] [--roles-dir DIR] [--policy JSON_PATH]
  tws-permissions show USER [--db PATH]
  tws-permissions export [--db PATH]            # JSON dump to stdout
  tws-permissions import-dump DUMP.json [--db PATH]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List, Optional

from tinywebstack_permissions.store import (
    PermissionsDB,
    default_role_seed_files,
    get_db_path,
)


def _db_path(args: argparse.Namespace):
    return Path(args.db) if getattr(args, "db", None) else get_db_path()


def cmd_seed(args: argparse.Namespace) -> int:
    path = _db_path(args)
    path.parent.mkdir(parents=True, exist_ok=True)
    role_files: List[Path] = []
    if args.roles_dir:
        d = Path(args.roles_dir)
        role_files = sorted(d.glob("*.yaml")) + sorted(d.glob("*.yml"))
        if not role_files:
            print(f"No role YAML files under {d}", file=sys.stderr)
            return 1
    else:
        role_files = [p for p in default_role_seed_files() if p.is_file()]
        if not role_files:
            print("Bundled role seed files missing", file=sys.stderr)
            return 1
    with PermissionsDB(path) as db:
        seeded = db.seed_roles(role_files)
        imported_from = ""
        if args.policy:
            policy = Path(args.policy)
            if policy.is_file():
                db.import_legacy_policy_file(policy)
                imported_from = str(policy)
        dump = db.export_dict()
    print(
        f"Seeded {path} (roles: {', '.join(sorted(set(seeded)))}"
        + (f"; imported household from {imported_from}" if imported_from else "")
        + f"; users: {len(dump.get('users', []))})"
    )
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    path = _db_path(args)
    if not path.is_file():
        print(f"No permissions DB at {path}", file=sys.stderr)
        return 1
    with PermissionsDB(path) as db:
        ps = db.get_permissions(args.user)
        if ps is None:
            print(f"Unknown user: {args.user}", file=sys.stderr)
            return 1
        print(json.dumps(ps.to_dict(), indent=2, sort_keys=True))
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    path = _db_path(args)
    if not path.is_file():
        print(f"No permissions DB at {path}", file=sys.stderr)
        return 1
    with PermissionsDB(path) as db:
        json.dump(db.export_dict(), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    return 0


def cmd_import_dump(args: argparse.Namespace) -> int:
    path = _db_path(args)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.loads(Path(args.dump).read_text(encoding="utf-8"))
    with PermissionsDB(path) as db:
        db.import_dict(data)
    print(f"Imported permissions dump into {path}")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    path = _db_path(args)
    if not path.is_file():
        print(f"No permissions DB at {path}", file=sys.stderr)
        return 1
    with PermissionsDB(path) as db:
        if args.role:
            db.set_role(args.user, args.role)
        if args.value is not None:
            try:
                parsed = json.loads(args.value)
            except json.JSONDecodeError:
                parsed = args.value
            db.set_permission(args.user, args.key, parsed)
        elif args.revoke:
            db.revoke_permission(args.user, args.key)
        ps = db.get_permissions(args.user)
    if ps is None:
        print(f"Unknown user: {args.user}", file=sys.stderr)
        return 1
    print(json.dumps(ps.to_dict(), indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tws-permissions")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_seed = sub.add_parser("seed", help="Create/populate the DB from role YAMLs")
    p_seed.add_argument("--db")
    p_seed.add_argument("--roles-dir")
    p_seed.add_argument("--policy", help="Optional family-policy.json to import")
    p_seed.set_defaults(fn=cmd_seed)

    p_show = sub.add_parser("show", help="Print effective permissions for a user")
    p_show.add_argument("user")
    p_show.add_argument("--db")
    p_show.set_defaults(fn=cmd_show)

    p_export = sub.add_parser("export", help="Dump the full DB as JSON")
    p_export.add_argument("--db")
    p_export.set_defaults(fn=cmd_export)

    p_import = sub.add_parser("import-dump", help="Restore an export dump")
    p_import.add_argument("dump")
    p_import.add_argument("--db")
    p_import.set_defaults(fn=cmd_import_dump)

    p_set = sub.add_parser("set", help="Set a role or permission override")
    p_set.add_argument("user")
    p_set.add_argument("key")
    p_set.add_argument("--value")
    p_set.add_argument("--role")
    p_set.add_argument("--revoke", action="store_true")
    p_set.add_argument("--db")
    p_set.set_defaults(fn=cmd_set)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
