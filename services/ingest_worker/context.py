"""Contextual chunking — a free, no-LLM variant of Anthropic Contextual Retrieval.

Each chunk is prefixed with a one-line situating header derived from the parent
document's metadata (source_type · agent · date, title, tags). The header is
embedded and FTS-indexed along with the chunk, so a chunk becomes findable by
document-level queries and the embedding is anchored to the document's topic —
without the per-chunk LLM call the original method requires (we cannot call the
Anthropic API and the VPS RAM is already committed to the embed + rerank models).
"""
from __future__ import annotations

import re
from typing import Any

_H1_RE = re.compile(r"^\s{0,3}#\s+(.+?)\s*#*\s*$", re.MULTILINE)
_DATE_PREFIX_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-")


def _extract_title(body: str, path: str) -> str:
    """First markdown H1 in the body, else a humanized filename slug."""
    if body:
        m = _H1_RE.search(body)
        if m:
            return m.group(1).strip()
    # Fallback: filename without dir, leading date, and extension.
    name = path.rsplit("/", 1)[-1]
    name = re.sub(r"\.md$", "", name, flags=re.IGNORECASE)
    name = _DATE_PREFIX_RE.sub("", name)
    return name.replace("-", " ").replace("_", " ").strip()


def _extract_date(frontmatter: dict[str, Any] | None) -> str:
    """Day-precision date from frontmatter ``created`` (``YYYY-MM-DD``)."""
    if not frontmatter:
        return ""
    raw = frontmatter.get("created") or frontmatter.get("updated") or ""
    return str(raw)[:10]


def build_context_prefix(
    *,
    path: str,
    source_type: str | None,
    agent: str | None,
    frontmatter: dict[str, Any] | None,
    body: str,
) -> str:
    """Build a one-line situating prefix from document metadata.

    Shape: ``[source_type · agent · date] Title — теги: t1, t2``. Any missing
    field is omitted; an all-empty document still yields a (possibly bare)
    string rather than raising.
    """
    date = _extract_date(frontmatter)
    head_bits = [b for b in (source_type, agent, date) if b]
    parts: list[str] = []
    if head_bits:
        parts.append("[" + " · ".join(head_bits) + "]")

    title = _extract_title(body, path)
    if title:
        parts.append(title)

    tags = (frontmatter or {}).get("tags") or []
    if isinstance(tags, list) and tags:
        parts.append("теги: " + ", ".join(str(t) for t in tags))

    return " ".join(parts)


# e5 instruction prefix for stored passages. multilingual-e5-large was trained
# with "query: " / "passage: " prefixes; embedding without them degrades
# retrieval quality. The prefix goes ONLY on the text handed to the embedder —
# never on the stored content, which feeds FTS + rerank and must stay clean.
# The matching "query: " prefix lives in memory_router_mcp.search (query side).
PASSAGE_PREFIX = "passage: "


def to_passage_inputs(chunks: list[str]) -> list[str]:
    """Prefix each chunk with the e5 ``passage: `` instruction for embedding."""
    return [PASSAGE_PREFIX + c for c in chunks]


def contextualize_chunks(chunks: list[str], prefix: str) -> list[str]:
    """Prepend ``prefix`` to each chunk, separated by a blank line.

    An empty prefix is a no-op (returns the chunks unchanged) so callers need
    not special-case documents with no usable metadata.
    """
    if not prefix:
        return chunks
    return [f"{prefix}\n\n{chunk}" for chunk in chunks]
