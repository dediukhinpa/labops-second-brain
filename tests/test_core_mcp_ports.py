"""Порты core_mcp переопределяются каноническими переменными окружения.

Дымовой прогон 23.11.2026: core_mcp брал порты только из DEFAULT_PORT модулей,
и песочницу на нестандартных портах пришлось поднимать через подмену _SERVICES.
"""
from __future__ import annotations

import os
from types import ModuleType

import pytest

# memory_mcp.server создаёт Config при импорте и требует PG_PASSWORD/MCP_PORT;
# сеть и БД при этом не трогаются.
os.environ.setdefault("PG_PASSWORD", "test")
os.environ.setdefault("MCP_PORT", "0")

from services.core_mcp import __main__ as core  # noqa: E402

# Прежние порты: без переменных окружения поведение не должно меняться.
_EXPECTED_DEFAULTS: dict[str, int] = {"memory": 5001, "agent_router": 5000, "task": 5003}


def _ports(services: list[tuple[str, ModuleType, int]]) -> dict[str, int]:
    """Свести список сервисов к словарю label -> port."""
    return {label: port for label, _mod, port in services}


def test_defaults_unchanged_without_env() -> None:
    """Пустое окружение — порты из DEFAULT_PORT, как раньше."""
    assert _ports(core._resolve_services(core._SERVICES, {})) == _EXPECTED_DEFAULTS


def test_empty_value_means_default() -> None:
    """Пустая строка в переменной не ломает запуск, а значит «по умолчанию»."""
    env = {"MCP_MEMORY_PORT": "", "MCP_TASK_PORT": "  "}
    assert _ports(core._resolve_services(core._SERVICES, env)) == _EXPECTED_DEFAULTS


def test_each_service_overridable() -> None:
    """Каждый сервис читает свою переменную, остальные не задеваются."""
    env = {"MCP_MEMORY_PORT": "15001", "MCP_AGENT_ROUTER_PORT": "15000", "MCP_TASK_PORT": "15003"}
    assert _ports(core._resolve_services(core._SERVICES, env)) == {
        "memory": 15001,
        "agent_router": 15000,
        "task": 15003,
    }
    only_task = {"MCP_TASK_PORT": "15003"}
    assert _ports(core._resolve_services(core._SERVICES, only_task)) == {
        **_EXPECTED_DEFAULTS,
        "task": 15003,
    }


def test_generic_mcp_port_is_ignored() -> None:
    """Общий MCP_PORT (порт отдельного юнита) не влияет на три порта core."""
    env = {"MCP_PORT": "9999"}
    assert _ports(core._resolve_services(core._SERVICES, env)) == _EXPECTED_DEFAULTS


def test_bad_value_fails_loudly() -> None:
    """Нечисловой порт — ошибка при старте, а не молчаливый дефолт."""
    with pytest.raises(ValueError):
        core._resolve_services(core._SERVICES, {"MCP_MEMORY_PORT": "abc"})


def test_every_service_has_port_env() -> None:
    """У каждого сервиса из _SERVICES есть своя переменная порта."""
    assert {label for label, _m, _p in core._SERVICES} == set(core._PORT_ENV)
