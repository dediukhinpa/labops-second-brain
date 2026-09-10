"""Тесты единой настройки логирования MCP-сервисов.

Регрессия, которую они держат: связка `basicConfig(level=INFO)` +
`uvicorn.run(log_level="info")` писала по две строки на каждый обслуженный
вызов, и штатный опрос task-poller'ами раздувал журнал на ~35 МБ в сутки.
"""
import logging

import pytest

from services.shared import logging_setup


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """Убрать переменные уровней, чтобы тест видел именно дефолты."""
    for name in (
        "SECOND_BRAIN_LOG_LEVEL",
        "SECOND_BRAIN_REQUEST_LOG_LEVEL",
        "SECOND_BRAIN_ACCESS_LOG_LEVEL",
    ):
        monkeypatch.delenv(name, raising=False)


def test_request_logger_is_silenced_by_default():
    """Построчный лог входящих вызовов по умолчанию молчит -- это и был шум."""
    logging_setup.configure_logging()
    level = logging.getLogger("mcp.server.lowlevel.server").getEffectiveLevel()
    assert level == logging.WARNING


def test_uvicorn_access_log_off_by_default():
    """На "info" uvicorn пишет строку на каждый HTTP-запрос -- не наш случай."""
    assert logging_setup.uvicorn_log_level() == "warning"


def test_application_logs_stay_informative():
    """Прикладные логи не глушим: они редкие и по ним разбирают инциденты."""
    logging_setup.configure_logging()
    assert logging.getLogger().getEffectiveLevel() == logging.INFO


def test_request_level_overridable(monkeypatch):
    """Для отладки шум включается обратно без правки кода."""
    monkeypatch.setenv("SECOND_BRAIN_REQUEST_LOG_LEVEL", "info")
    logging_setup.configure_logging()
    level = logging.getLogger("mcp.server.lowlevel.server").getEffectiveLevel()
    assert level == logging.INFO


def test_access_level_overridable(monkeypatch):
    """uvicorn ожидает уровень строчными -- регистр из окружения не должен ломать."""
    monkeypatch.setenv("SECOND_BRAIN_ACCESS_LOG_LEVEL", "INFO")
    assert logging_setup.uvicorn_log_level() == "info"


def test_empty_env_falls_back_to_default(monkeypatch):
    """Пустая переменная -- это "не задано", а не пустой уровень."""
    monkeypatch.setenv("SECOND_BRAIN_ACCESS_LOG_LEVEL", "")
    assert logging_setup.uvicorn_log_level() == "warning"
