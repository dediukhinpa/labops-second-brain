"""Tests for note file naming: Cyrillic slugs, empty-slug fallback, collisions."""
from __future__ import annotations

from pathlib import Path

import pytest

from services.memory_mcp.tools import (
    FALLBACK_SLUG_HASH_LEN,
    _note_slug,
    _resolve_note_path,
    _slugify,
)
from tests.test_create_decision_note_supersession import (
    _call_create,
    _make_pool,
    _make_recorder,
)

SCOPE = "decisions"
PREFIX = "2026-11-14-"


def _write_note(root: Path, rel_path: str, title: str) -> None:
    """Write a note file shaped like the ones the MCP tools produce."""
    path = root / rel_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\ntype: decision\n---\n\n# {title}\n\nbody\n", encoding="utf-8")


class TestCyrillicSlug:
    def test_transliteration(self) -> None:
        assert _slugify("Фильтр ПДн пропускает картинки") == "filtr-pdn-propuskaet-kartinki"

    def test_special_letters(self) -> None:
        assert _slugify("Щука, ёж и объём") == "shchuka-yozh-i-obyom"

    def test_mixed_with_latin_and_digits(self) -> None:
        assert _slugify("Деплой v2 на prod") == "deploy-v2-na-prod"

    def test_latin_behaviour_unchanged(self) -> None:
        assert _slugify("Fix: #123 -- urgent!") == "fix-123-urgent"

    def test_max_length_after_transliteration(self) -> None:
        assert len(_slugify("щ" * 200)) <= 60


class TestEmptySlugFallback:
    def test_symbols_only_gets_hash(self) -> None:
        slug = _note_slug("!@#$%")
        assert slug.startswith("note-")
        assert len(slug) == len("note-") + FALLBACK_SLUG_HASH_LEN

    def test_hash_is_stable_and_title_specific(self) -> None:
        assert _note_slug("!!!") == _note_slug("!!!")
        assert _note_slug("!!!") != _note_slug("???")

    def test_non_cyrillic_script_gets_hash(self) -> None:
        assert _note_slug("日本語").startswith("note-")

    def test_nonempty_slug_not_hashed(self) -> None:
        assert _note_slug("Привет") == "privet"


class TestResolveNotePath:
    def test_free_path(self, tmp_path: Path) -> None:
        got = _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "Привет")
        assert got == "decisions/2026-11-14-privet.md"

    def test_same_title_is_same_document(self, tmp_path: Path) -> None:
        _write_note(tmp_path, "decisions/2026-11-14-privet.md", "Привет")
        got = _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "Привет")
        assert got == "decisions/2026-11-14-privet.md"

    def test_other_title_same_slug_gets_suffix(self, tmp_path: Path) -> None:
        _write_note(tmp_path, "decisions/2026-11-14-privet.md", "Привет")
        got = _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "ПРИВЕТ!")
        assert got == "decisions/2026-11-14-privet-2.md"

    def test_suffix_chain(self, tmp_path: Path) -> None:
        _write_note(tmp_path, "decisions/2026-11-14-privet.md", "Привет")
        _write_note(tmp_path, "decisions/2026-11-14-privet-2.md", "ПРИВЕТ!")
        assert (
            _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "привет?")
            == "decisions/2026-11-14-privet-3.md"
        )
        # The second note is still the same document for its own title.
        assert (
            _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "ПРИВЕТ!")
            == "decisions/2026-11-14-privet-2.md"
        )

    def test_legacy_empty_slug_file_not_touched(self, tmp_path: Path) -> None:
        legacy = "decisions/2026-11-14-.md"
        _write_note(tmp_path, legacy, "Старая заметка")
        before = (tmp_path / legacy).read_text(encoding="utf-8")
        got = _resolve_note_path(str(tmp_path), SCOPE, PREFIX, "Новая заметка")
        assert got == "decisions/2026-11-14-novaya-zametka.md"
        assert (tmp_path / legacy).read_text(encoding="utf-8") == before

    def test_undated_scope(self, tmp_path: Path) -> None:
        _write_note(tmp_path, "knowledge/note-x.md", "Другое")
        assert _resolve_note_path(str(tmp_path), "knowledge", "", "Тест") == "knowledge/test.md"


class TestCreateDecisionNoteCyrillic:
    @pytest.mark.asyncio
    async def test_two_cyrillic_notes_same_day_do_not_clobber(self, tmp_path: Path) -> None:
        recorder, ctx = _make_recorder(_make_pool(), str(tmp_path))
        first = await _call_create(recorder, ctx, "Первое решение", "альфа бета гамма")
        second = await _call_create(recorder, ctx, "Второе решение", "дельта эпсилон дзета")
        assert first != second
        files = sorted((tmp_path / "decisions").glob("*.md"))
        assert len(files) == 2
        texts = [f.read_text(encoding="utf-8") for f in files]
        assert any("Первое решение" in t for t in texts)
        assert any("Второе решение" in t for t in texts)

    @pytest.mark.asyncio
    async def test_same_slug_different_notes_get_suffix(self, tmp_path: Path) -> None:
        recorder, ctx = _make_recorder(_make_pool(), str(tmp_path))
        first = await _call_create(recorder, ctx, "Привет", "альфа бета гамма")
        second = await _call_create(recorder, ctx, "привет!", "дельта эпсилон дзета")
        assert first.endswith("privet.md")
        assert second.endswith("privet-2.md")
        assert len(list((tmp_path / "decisions").glob("*.md"))) == 2

    @pytest.mark.asyncio
    async def test_rewrite_of_same_note_keeps_path(self, tmp_path: Path) -> None:
        recorder, ctx = _make_recorder(_make_pool(), str(tmp_path))
        first = await _call_create(recorder, ctx, "Привет", "альфа бета гамма")
        again = await _call_create(recorder, ctx, "Привет", "альфа бета гамма")
        assert first.split(": ", 1)[1] == again.split(": ", 1)[1]
        assert len(list((tmp_path / "decisions").glob("*.md"))) == 1

    @pytest.mark.asyncio
    async def test_symbols_only_title_gets_hash_name(self, tmp_path: Path) -> None:
        recorder, ctx = _make_recorder(_make_pool(), str(tmp_path))
        result = await _call_create(recorder, ctx, "!!!", "альфа бета гамма")
        name = result.split("/")[-1]
        assert "-note-" in name
