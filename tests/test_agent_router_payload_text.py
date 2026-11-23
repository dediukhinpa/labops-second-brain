"""Текст задачи notify доходит до получателя и из `body`, и из `text`."""

from __future__ import annotations

import asyncio
import json
from typing import Any

import pytest

from services.agent_router_mcp import worker as worker_mod


class _Resp:
    status_code = 200
    text = "ok"


class _Client:
    """Подменяет httpx.AsyncClient: запоминает тело запроса."""

    def __init__(self) -> None:
        self.bodies: list[dict[str, Any]] = []

    async def post(
        self, url: str, *, content: bytes, headers: dict[str, str], timeout: float
    ) -> _Resp:
        self.bodies.append(json.loads(content))
        return _Resp()


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        ({"title": "t", "body": "из body"}, "из body"),
        ({"title": "t", "text": "из text"}, "из text"),
        ({"title": "t", "body": "главный", "text": "запасной"}, "главный"),
        ({"title": "t"}, ""),
    ],
)
def test_payload_body_prefers_body_then_text(payload: dict[str, Any], expected: str) -> None:
    assert worker_mod._payload_body(payload) == expected


def test_virtual_prompt_carries_text_field() -> None:
    prompt = worker_mod._format_virtual_prompt(
        from_agent="agent-1",
        to_agent="agent-2",
        task_id="agent-1::agent-2::0001",
        payload={"title": "Задача", "text": "СЛОВО-ИЗ-TEXT"},
    )
    assert "СЛОВО-ИЗ-TEXT" in prompt


def test_gateway_body_carries_text_field(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GATEWAY_WEBHOOK_TOKEN", "test-bearer")
    monkeypatch.delenv("AGENT_GATEWAY_AUTH", raising=False)
    client = _Client()
    row = {
        "id": 1,
        "task_id": "a::b::1",
        "from_agent": "a",
        "to_agent": "b",
        "payload_json": json.dumps({"title": "Задача", "text": "СЛОВО-ИЗ-TEXT"}),
        "attempts": 0,
        "max_attempts": 5,
    }
    status, err = asyncio.run(
        worker_mod._deliver_one(client, {"b": "http://gw/b"}, row, {})  # type: ignore[arg-type]
    )
    assert status == "acked", err
    assert client.bodies[0]["body"] == "СЛОВО-ИЗ-TEXT"
    assert "СЛОВО-ИЗ-TEXT" in client.bodies[0]["message"]
