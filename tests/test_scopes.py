"""Pure-logic tests for the scope canonicalisation layer (no DB)."""
import pytest

from services.shared.scopes import (
    CANONICAL_SCOPES,
    SCOPE_ALIASES,
    normalize_scope,
    scope_equivalents,
)
from services.memory_mcp.path_guard import validate_path


def test_legacy_names_map_to_canonical():
    assert normalize_scope("30-decisions") == "decisions"
    assert normalize_scope("90-inbox") == "inbox"
    assert normalize_scope("15-personal") == "personal"
    # the two "tasks" concepts disambiguate
    assert normalize_scope("60-tasks") == "tasks"        # vault folder
    assert normalize_scope("10-tasks") == "task-board"   # Postgres task board


def test_canonical_and_unknown_pass_through():
    assert normalize_scope("decisions") == "decisions"
    assert normalize_scope("task-board") == "task-board"
    assert normalize_scope("whatever") == "whatever"
    assert normalize_scope(None) is None


def test_every_alias_target_is_canonical():
    for target in SCOPE_ALIASES.values():
        assert target in CANONICAL_SCOPES


def test_scope_equivalents_match_old_and_new():
    # querying the new name must still find rows stored under the old name
    assert scope_equivalents("decisions") == {"decisions", "30-decisions"}
    # querying the old name resolves to the same set
    assert scope_equivalents("30-decisions") == {"decisions", "30-decisions"}


def test_path_guard_accepts_new_and_legacy(tmp_path):
    (tmp_path / "decisions").mkdir()
    # new semantic path
    validate_path("decisions/note.md", str(tmp_path))
    # legacy numbered path still resolves AND lands under the canonical folder
    resolved = validate_path("30-decisions/note.md", str(tmp_path))
    assert resolved == (tmp_path / "decisions" / "note.md")


def test_path_guard_rejects_unknown(tmp_path):
    with pytest.raises(ValueError):
        validate_path("99-nope/x.md", str(tmp_path))
