"""Единая настройка логирования для MCP-сервисов.

Вынесено из пяти одинаковых копий `logging.basicConfig(level=INFO)` +
`uvicorn.run(..., log_level="info")`. Такая связка писала по две строки INFO на
каждый обслуженный вызов: access-лог uvicorn и "Processing request of type
CallToolRequest" из MCP SDK. При штатном опросе task-poller'ами (5 с на агента)
это давало ~275 тыс. строк и ~35 МБ в сутки -- журнал вырастал до гигабайтов на
ровном месте, хотя ни одной ошибки в нём не было.

Прикладные логи остаются на INFO: они редкие и полезные. Глушится именно
пооперационный шум, и оба уровня переопределяются из окружения, чтобы поднять
многословность при отладке без правки кода.
"""
import logging
import os

LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"

# Логгер MCP SDK, пишущий строку на каждый входящий вызов.
_MCP_REQUEST_LOGGER = "mcp.server.lowlevel.server"

DEFAULT_LEVEL = "INFO"
# Пооперационный шум по умолчанию молчит: на здоровой системе он лишь дублирует
# то, что и так видно в метриках, а на больной тонет в собственном объёме.
DEFAULT_REQUEST_LEVEL = "WARNING"
DEFAULT_ACCESS_LEVEL = "warning"


def _level_from_env(name: str, default: str) -> str:
    """Прочитать уровень логирования из окружения.

    Args:
        name: Имя переменной окружения.
        default: Значение, если переменная не задана или пуста.

    Returns:
        Имя уровня в верхнем регистре.
    """
    return (os.environ.get(name) or default).upper()


def configure_logging() -> None:
    """Настроить корневой логгер и приглушить пооперационный шум MCP SDK.

    Уровни: ``LOG_LEVEL`` -- прикладные логи (по умолчанию INFO),
    ``SECOND_BRAIN_REQUEST_LOG_LEVEL`` -- построчный лог входящих вызовов
    (по умолчанию WARNING, то есть выключен).
    """
    level = _level_from_env("LOG_LEVEL", DEFAULT_LEVEL)
    logging.basicConfig(level=level, format=LOG_FORMAT)
    # basicConfig молча ничего не делает, если у корневого логгера уже есть
    # обработчик (его мог поставить импортированный раньше модуль). Уровень
    # тогда остался бы чужим, поэтому выставляем его отдельно и явно.
    logging.getLogger().setLevel(level)
    logging.getLogger(_MCP_REQUEST_LOGGER).setLevel(
        _level_from_env("SECOND_BRAIN_REQUEST_LOG_LEVEL", DEFAULT_REQUEST_LEVEL)
    )


def uvicorn_log_level() -> str:
    """Уровень для uvicorn: на "info" он пишет строку на каждый HTTP-запрос.

    Returns:
        Имя уровня в нижнем регистре -- uvicorn ожидает именно такое.
    """
    return _level_from_env(
        "SECOND_BRAIN_ACCESS_LOG_LEVEL", DEFAULT_ACCESS_LEVEL
    ).lower()
