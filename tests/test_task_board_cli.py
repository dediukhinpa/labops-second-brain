"""CLI доски задач (scripts/task-board-second_brain.sh) против сервера с MCP-сессиями.

task-mcp — Streamable HTTP с сессиями: без initialize и заголовка Mcp-Session-Id он
отвечает «400 Missing session ID». CLI так и слал tools/call без сессии и не работал
ни одной командой (HRV, 26.11.2026). Здесь поддельный сервер ведёт себя так же
строго, а тест проверяет и вызов, и закрытие сессии (брошенные сессии текут).
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CLI = REPO_ROOT / "scripts" / "task-board-second_brain.sh"
SESSION_ID = "sess-test-1"
TOKEN = "tok-test"
CLI_TIMEOUT_SECONDS = 30


@dataclass
class Seen:
    """Что поддельный сервер получил от CLI."""

    calls: list[dict] = field(default_factory=list)
    auth: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)
    tool_error: bool = False


def _make_handler(seen: Seen) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:  # тише в выводе pytest
            return

        def _reply(self, code: int, body: str = "", extra: dict[str, str] | None = None) -> None:
            self.send_response(code)
            self.send_header("Content-Type", "text/event-stream")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body.encode())

        def do_POST(self) -> None:  # noqa: N802 — имя задаёт http.server
            msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seen.auth.append(self.headers.get("Authorization", ""))
            method = msg.get("method")
            if method == "initialize":
                result = {"protocolVersion": "2025-03-26", "capabilities": {},
                          "serverInfo": {"name": "fake-task-mcp", "version": "1"}}
                self._reply(200, "event: message\ndata: "
                            + json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result})
                            + "\n\n", {"Mcp-Session-Id": SESSION_ID})
                return
            if self.headers.get("Mcp-Session-Id") != SESSION_ID:
                self._reply(400, '{"error":{"message":"Bad Request: Missing session ID"}}')
                return
            if method == "notifications/initialized":
                self._reply(202)
                return
            seen.calls.append(msg["params"])
            if seen.tool_error:
                result = {"isError": True, "content": [{"type": "text", "text": "bad transition"}]}
            else:
                args = msg["params"]["arguments"]
                result = {"structuredContent": {"id": args.get("task_id"), "status": "done"},
                          "content": []}
            self._reply(200, "event: message\ndata: "
                        + json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result})
                        + "\n\n")

        def do_DELETE(self) -> None:  # noqa: N802
            seen.deleted.append(self.headers.get("Mcp-Session-Id", ""))
            self._reply(200)

    return Handler


@pytest.fixture
def server() -> Iterator[tuple[int, Seen]]:
    """Поддельный task-mcp на свободном порту."""
    seen = Seen()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(seen))
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    try:
        yield srv.server_address[1], seen
    finally:
        srv.shutdown()


def _run(port: int, *args: str) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "SECOND_BRAIN_TOKEN": TOKEN,
           "TASK_MCP_HOST": "127.0.0.1", "TASK_MCP_PORT": str(port)}
    return subprocess.run(["bash", str(CLI), *args], capture_output=True, text=True,
                          env=env, timeout=CLI_TIMEOUT_SECONDS, check=False)


def test_done_opens_session_calls_tool_and_closes(server: tuple[int, Seen]) -> None:
    """done TASK_ID: вызов в сессии, аргументы как в командной строке, сессия закрыта."""
    port, seen = server
    res = _run(port, "done", "7", "--note", "shipped")
    assert res.returncode == 0, res.stderr
    assert json.loads(res.stdout) == {"id": 7, "status": "done"}
    assert seen.calls == [{"name": "task_done", "arguments": {"task_id": 7, "note": "shipped"}}]
    assert set(seen.auth) == {f"Bearer {TOKEN}"}
    assert seen.deleted == [SESSION_ID]


def test_tool_error_fails_and_still_closes_session(server: tuple[int, Seen]) -> None:
    """Ошибка инструмента — ненулевой код и текст ошибки, но сессия всё равно закрыта."""
    port, seen = server
    seen.tool_error = True
    res = _run(port, "start", "3", "--note", "go")
    assert res.returncode != 0
    assert "bad transition" in res.stderr
    assert seen.deleted == [SESSION_ID]


def test_token_never_printed(server: tuple[int, Seen]) -> None:
    """Токен не попадает ни в stdout, ни в stderr."""
    port, _seen = server
    res = _run(port, "get", "1")
    assert TOKEN not in res.stdout + res.stderr
