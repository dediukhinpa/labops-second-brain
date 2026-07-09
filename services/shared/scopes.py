"""Canonical vault scopes + backwards-compatible aliases.

The vault used to name folders with Johnny-Decimal-style numeric prefixes
(``30-decisions``). Those numbers were opaque to the system — RBAC, recall and
ingest all treat a scope as an opaque string — and were applied inconsistently
(duplicate prefixes; the ``10-tasks`` board scope vs the ``60-tasks`` folder).
Scopes are now plain semantic names.

``SCOPE_ALIASES`` keeps the legacy numbered names working during the migration
window: :func:`normalize_scope` maps an old name to its canonical name, and
:func:`scope_equivalents` expands a name to every equivalent form so a recall
query matches rows whether they were stored under the old or the new name.
Migration ``007_scope_rename.sql`` rewrites the stored values; once it has run on
a deployment the aliases are only a safety net.

The ``runbooks`` scope was retired in migration ``008_remove_runbooks_scope.sql``
(the tool and folder saw no real usage); both ``runbooks`` and the legacy
``70-runbooks`` now alias to ``knowledge``, the closest remaining semantic fit.
"""
from __future__ import annotations

# Canonical RBAC scopes — what tokens grant and what the system stores.
CANONICAL_SCOPES = frozenset({
    "strategy",
    "system",
    "personal",
    "daily",
    "metrics",
    "decisions",
    "projects",
    "external",
    "knowledge",
    "tasks",
    "task-board",
    "error-patterns",
    "inbox",
})

# Meta scopes that are not regular content folders.
META_SCOPES = frozenset({"_templates", "slots"})

# Scopes valid as a vault *path* prefix: every content folder plus ``_templates``,
# minus the board-only RBAC scope ``task-board`` (the task board lives in Postgres,
# not the vault filesystem).
ALLOWED_PATH_SCOPES = (CANONICAL_SCOPES - {"task-board"}) | {"_templates"}

# Legacy numbered name -> canonical semantic name (accepted during the window).
SCOPE_ALIASES = {
    "10-strategy": "strategy",
    "10-system": "system",
    "15-personal": "personal",
    "20-daily": "daily",
    "20-metrics": "metrics",
    "30-decisions": "decisions",
    "40-projects": "projects",
    "50-external": "external",
    "50-knowledge": "knowledge",
    "60-tasks": "tasks",
    "10-tasks": "task-board",
    "70-runbooks": "knowledge",
    "runbooks": "knowledge",
    "80-error-patterns": "error-patterns",
    "90-inbox": "inbox",
}

# Reverse index: canonical name -> list of legacy names that map to it.
_LEGACY_BY_CANONICAL: dict[str, list[str]] = {}
for _old, _new in SCOPE_ALIASES.items():
    _LEGACY_BY_CANONICAL.setdefault(_new, []).append(_old)


def normalize_scope(scope: str | None) -> str | None:
    """Map a legacy numbered scope to its canonical name.

    Canonical and unknown values pass through unchanged (validation happens at
    the call site). ``None`` passes through so callers can normalize an optional
    scope without a guard.
    """
    if scope is None:
        return None
    s = scope.strip()
    return SCOPE_ALIASES.get(s, s)


def scope_equivalents(scope: str) -> set[str]:
    """All names equivalent to ``scope`` (itself, its canonical name, and every
    legacy alias of that canonical name).

    Used to filter persisted rows that may still carry the old numbered name
    before migration 007 has run on a deployment.
    """
    canonical = normalize_scope(scope)
    out = {scope, canonical}
    out.update(_LEGACY_BY_CANONICAL.get(canonical, ()))
    return {s for s in out if s}
