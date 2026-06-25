"""Tests for contextual chunking — situating prefix prepended before embedding.

Free/no-LLM variant of Anthropic Contextual Retrieval: each chunk is prefixed
with a one-line document context (source_type · agent · date, title, tags) so
the embedding and BM25 index situate the chunk within its parent document.
"""
from __future__ import annotations

from services.ingest_worker.context import (
    PASSAGE_PREFIX,
    build_context_prefix,
    contextualize_chunks,
    to_passage_inputs,
)


def test_to_passage_inputs_prefixes_each_chunk() -> None:
    out = to_passage_inputs(["alpha", "beta"])
    assert out == ["passage: alpha", "passage: beta"]
    assert all(c.startswith(PASSAGE_PREFIX) for c in out)


def test_to_passage_inputs_empty() -> None:
    assert to_passage_inputs([]) == []


def test_prefix_includes_source_agent_date_title_tags() -> None:
    fm = {"created": "2026-06-24T09:03:01Z", "tags": ["csharp", "ozon"]}
    p = build_context_prefix(
        path="30-decisions/2026-06-24-c-net.md",
        source_type="decision",
        agent="polly",
        frontmatter=fm,
        body="# Вакансии C# за 24 июня\n\nТекст решения...",
    )
    assert "decision" in p
    assert "polly" in p
    assert "2026-06-24" in p           # date truncated to day
    assert "Вакансии C#" in p          # title from first H1
    assert "csharp" in p and "ozon" in p


def test_title_falls_back_to_filename_without_h1() -> None:
    p = build_context_prefix(
        path="80-error-patterns/2026-06-13-tmux-kill-mode.md",
        source_type="error-pattern",
        agent=None,
        frontmatter={},
        body="Просто текст без заголовка.",
    )
    # date prefix and extension stripped, slug humanized
    assert "tmux kill mode" in p.lower()
    assert ".md" not in p
    assert "2026-06-13-" not in p


def test_robust_to_empty_metadata() -> None:
    # No frontmatter, empty body, missing fields → never raises, non-empty-ish.
    p = build_context_prefix(
        path="x.md", source_type=None, agent=None, frontmatter=None, body=""
    )
    assert isinstance(p, str)


def test_contextualize_prepends_prefix_to_each_chunk() -> None:
    chunks = ["первый кусок", "второй кусок", "третий"]
    out = contextualize_chunks(chunks, "[decision · polly] Заголовок")
    assert len(out) == len(chunks)
    for original, ctx in zip(chunks, out):
        assert ctx.startswith("[decision · polly] Заголовок")
        assert ctx.endswith(original)
        assert original in ctx


def test_contextualize_empty_prefix_returns_chunks_unchanged() -> None:
    chunks = ["a", "b"]
    assert contextualize_chunks(chunks, "") == chunks


def test_contextualize_empty_chunks() -> None:
    assert contextualize_chunks([], "[decision] T") == []
