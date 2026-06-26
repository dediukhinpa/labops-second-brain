"""Tests for create_personal_note / create_project_note + personal scope.

personal/project notes split data by SUBJECT (the human vs the business),
orthogonal to the structural note types (decision/runbook/error/external).
Both scopes are team-wide read/write (operator decision 2026-06-25).
"""
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from services.memory_mcp.path_guard import ALLOWED_SCOPES
from services.memory_mcp.tools import _REQUEST_AUTH, register_tools
from services.shared.auth import AgentContext
from services.shared.tool_gating import should_register_tool


# --- minimal fakes (self-contained; mirror test_memory_mcp.py) ---
class ToolRecorder:
    def __init__(self) -> None:
        self.tools: dict[str, object] = {}

    def tool(self, **kwargs):  # noqa: ANN001
        def decorator(fn):
            self.tools[fn.__name__] = fn
            return fn
        return decorator


class FakePool:
    def __init__(self) -> None:
        self.fetchrow_results: list[object] = []
        self.fetchrow_calls: list[tuple] = []
        self.execute_calls: list[tuple] = []

    async def fetchrow(self, query: str, *args):  # noqa: ANN001
        self.fetchrow_calls.append((query, args))
        return self.fetchrow_results.pop(0) if self.fetchrow_results else None

    async def fetchval(self, query: str, *args):  # noqa: ANN001
        row = await self.fetchrow(query, *args)
        if row is None:
            return None
        if isinstance(row, dict):
            return next(iter(row.values()))
        return row[0]

    async def execute(self, query: str, *args):  # noqa: ANN001
        self.execute_calls.append((query, args))
        return None


def _register(tmp_path: Path, recorder: ToolRecorder, pool: FakePool) -> None:
    async def pool_fn() -> object:
        return pool
    register_tools(recorder, str(tmp_path), pool_fn, tool_set="all")


async def _call_note(recorder, pool, ctx, tool_name, **kwargs):
    # New doc: SELECT existing -> None, INSERT ... RETURNING id -> 1
    pool.fetchrow_results = [None, {"id": 1}]
    with patch(
        "services.memory_mcp.tools.authenticate",
        new=AsyncMock(return_value=ctx),
    ):
        token = _REQUEST_AUTH.set("Bearer t")
        try:
            return await recorder.tools[tool_name](
                ctx={"headers": {"authorization": "Bearer t"}}, **kwargs
            )
        finally:
            _REQUEST_AUTH.reset(token)


# --- scope membership ---
def test_personal_scope_allowed() -> None:
    assert "personal" in ALLOWED_SCOPES

def test_projects_scope_allowed() -> None:
    assert "projects" in ALLOWED_SCOPES


# --- gating: both register in core (so all agents get them) ---
def test_personal_note_in_core_surface() -> None:
    assert should_register_tool("memory_mcp", "create_personal_note", "core")

def test_project_note_in_core_surface() -> None:
    assert should_register_tool("memory_mcp", "create_project_note", "core")


# --- create_personal_note ---
@pytest.mark.asyncio
async def test_create_personal_note_writes_personal_scope(tmp_path: Path) -> None:
    pool, recorder = FakePool(), ToolRecorder()
    _register(tmp_path, recorder, pool)
    ctx = AgentContext(agent="polly", write_scopes=["personal"], read_scopes=["*"])
    res = await _call_note(
        recorder, pool, ctx, "create_personal_note",
        title="Boss skill profile", body="Учит Python, 3 мес опыта.", tags=["skills"],
    )
    assert res.startswith("created: personal/")
    files = list((tmp_path / "personal").glob("*.md"))
    assert files, "expected a personal note file on disk"
    content = files[0].read_text(encoding="utf-8")
    assert "type: personal" in content
    assert "Boss skill profile" in content


@pytest.mark.asyncio
async def test_create_personal_note_rbac(tmp_path: Path) -> None:
    pool, recorder = FakePool(), ToolRecorder()
    _register(tmp_path, recorder, pool)
    ctx = AgentContext(agent="x", write_scopes=["decisions"], read_scopes=["*"])
    with pytest.raises(PermissionError, match="cannot write to personal"):
        await _call_note(
            recorder, pool, ctx, "create_personal_note",
            title="t", body="b", tags=[],
        )


# --- create_project_note ---
@pytest.mark.asyncio
async def test_create_project_note_writes_projects_scope(tmp_path: Path) -> None:
    pool, recorder = FakePool(), ToolRecorder()
    _register(tmp_path, recorder, pool)
    ctx = AgentContext(agent="christopher", write_scopes=["projects"], read_scopes=["*"])
    res = await _call_note(
        recorder, pool, ctx, "create_project_note",
        title="Договор с подрядчиком", body="Условия...", tags=["legal"],
    )
    assert res.startswith("created: projects/")
    files = list((tmp_path / "projects").glob("*.md"))
    assert files, "expected a project note file on disk"
    content = files[0].read_text(encoding="utf-8")
    assert "type: project" in content


@pytest.mark.asyncio
async def test_create_project_note_rbac(tmp_path: Path) -> None:
    pool, recorder = FakePool(), ToolRecorder()
    _register(tmp_path, recorder, pool)
    ctx = AgentContext(agent="x", write_scopes=["decisions"], read_scopes=["*"])
    with pytest.raises(PermissionError, match="cannot write to projects"):
        await _call_note(
            recorder, pool, ctx, "create_project_note",
            title="t", body="b", tags=[],
        )
