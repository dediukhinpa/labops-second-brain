"""Pure-logic tests for the scope canonicalisation layer (no DB)."""
from pathlib import Path

import pytest

from services.shared.scopes import (
    CANONICAL_SCOPES,
    SCOPE_ALIASES,
    normalize_scope,
    scope_equivalents,
)
from services.memory_mcp.path_guard import validate_path

REPO_ROOT = Path(__file__).resolve().parent.parent


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


def test_installer_default_scopes_cover_what_the_swarm_assumes() -> None:
    """Регрессия: агент, созданный установщиком, должен уметь то, что ему уже велено.

    Найдено 02.09.2026. Доска задач стала основным каналом межагентной работы, а
    ``task-board`` в дефолтных scope не появился — новые агенты видели задачу и
    не могли её взять; права доливались вручную. То же с ``error-patterns``:
    шаблон ``CLAUDE.md`` агента прямо велит писать «decisions/error-patterns to
    memory», а разрешения не выдавалось никому.
    """
    line = next(
        raw
        for raw in (REPO_ROOT / "scripts" / "connect-agents.sh").read_text(
            encoding="utf-8"
        ).splitlines()
        if raw.startswith("DEFAULT_SCOPES=")
    )
    scopes = line.split(":-", 1)[1].rstrip('}"').split(",")

    assert "task-board" in scopes, "без task-board агент не сможет работать с доской"
    assert "error-patterns" in scopes, (
        "CLAUDE.md агента велит писать error-patterns — без scope это запрещено"
    )
    unknown = [s for s in scopes if normalize_scope(s) not in CANONICAL_SCOPES]
    assert not unknown, f"неканонические scope в дефолте: {unknown}"
