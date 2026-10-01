"""Declarative role→permission store (SQLite) for tinywebStack family layer (F1.3).

The SQLite database is runtime state; two in-repo YAML role files act as
migrations that create/populate it. Enforcement code (Synapse spam checker,
Mobilizon helpers, family dashboard) reads the DB through this library —
enforcement logic stays where it lives, only the rule lookup is queried.

Fallback contract: when the DB file does not exist, callers must keep their
pre-F1.3 file-backed behaviour (family-policy.json). See
``SqliteFamilyPolicyStore`` and ``resolve_db_path``.
"""

from tinywebstack_permissions.store import (
    DEFAULT_DB_PATH,
    PERMISSION_KEYS,
    SCHEMA_VERSION,
    PermissionSet,
    PermissionsDB,
    SqliteFamilyPolicyStore,
    default_role_permissions,
    effective_db_path,
    get_db_path,
    load_role_yaml,
    resolve_db_path,
)

__all__ = [
    "DEFAULT_DB_PATH",
    "PERMISSION_KEYS",
    "SCHEMA_VERSION",
    "PermissionSet",
    "PermissionsDB",
    "SqliteFamilyPolicyStore",
    "default_role_permissions",
    "effective_db_path",
    "get_db_path",
    "load_role_yaml",
    "resolve_db_path",
]
