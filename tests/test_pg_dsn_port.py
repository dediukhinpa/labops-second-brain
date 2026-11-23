"""Config.get_pg_dsn передаёт порт и для unix-сокета.

Дымовой прогон 23.11.2026: при PG_HOST=/каталог порт не передавался, asyncpg
подставлял 5432 и искал сокет .s.PGSQL.5432 — кластер на другом порту был
недоступен (в песочнице обходили через PGPORT).
"""
from __future__ import annotations

import pytest

from services.shared.config import Config


@pytest.fixture(autouse=True)
def _base_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Минимальное окружение, без которого Config не создаётся."""
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "0")


@pytest.mark.parametrize("host", ["/var/run/postgresql", "/tmp/sandbox-pg"])
def test_unix_socket_keeps_custom_port(monkeypatch: pytest.MonkeyPatch, host: str) -> None:
    """Unix-сокет: нестандартный порт попадает в параметры подключения."""
    monkeypatch.setenv("PG_HOST", host)
    monkeypatch.setenv("PG_PORT", "15432")
    dsn = Config().get_pg_dsn()
    assert dsn["host"] == host
    assert dsn["port"] == 15432


def test_tcp_keeps_port(monkeypatch: pytest.MonkeyPatch) -> None:
    """TCP: порт передаётся, как и раньше."""
    monkeypatch.setenv("PG_HOST", "127.0.0.1")
    monkeypatch.setenv("PG_PORT", "6543")
    assert Config().get_pg_dsn()["port"] == 6543


def test_default_port_is_5432(monkeypatch: pytest.MonkeyPatch) -> None:
    """Без PG_PORT — 5432, то есть боевое подключение по сокету не меняется."""
    monkeypatch.delenv("PG_PORT", raising=False)
    monkeypatch.delenv("PG_HOST", raising=False)
    dsn = Config().get_pg_dsn()
    assert dsn["host"] == "/var/run/postgresql"
    assert dsn["port"] == 5432
