"""Сборка HTTP-приложения MCP с протуханием брошенных сессий.

ЗАЧЕМ ЭТОТ МОДУЛЬ СУЩЕСТВУЕТ
----------------------------
Транспорт streamable-http держит на сервере состояние сессии, пока клиент не
закроет её `HTTP DELETE`. У MCP SDK есть штатный предохранитель --
`StreamableHTTPSessionManager(session_idle_timeout=...)`, который сам убирает
сессии без запросов; в документации SDK рекомендованы 1800 секунд. Но FastMCP
2.13 создаёт менеджер БЕЗ этого параметра (`fastmcp/server/http.py`), то есть
по умолчанию сессии не протухают никогда.

Чем это кончилось на живом хосте 2026-09-01: поллер задач открывал сессию
каждые 5 секунд на агента и не закрывал её. Замер: 56 КБ на брошенную сессию
против 6 КБ на закрытую; 24 сессии в минуту ≈ 1.5 ГБ в сутки. За 30 часов
`memory_router` вырос до 4.9 ГБ (2.08 ГБ RSS + 2.90 ГБ swap) при норме
1.5--1.8 ГБ и выел весь swap хоста.

Клиентов мы починили (закрывают сессию), но полагаться только на дисциплину
клиентов нельзя: клиент, упавший в середине сессии, DELETE не пришлёт никогда.
Этот модуль включает серверный предохранитель.

Устройство: FastMCP не отдаёт менеджер сессий наружу, поэтому он ищется по
дереву маршрутов (у ASGI-обёртки транспорта есть атрибут `session_manager`).
Не нашли -- это НЕ повод падать: предупреждаем в лог и работаем как раньше.
"""

from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)

# Рекомендация документации MCP SDK для типового развёртывания.
DEFAULT_SESSION_IDLE_TIMEOUT_SEC = 1800.0

# Переменная окружения для оператора: 0 или пусто -- предохранитель выключен.
IDLE_TIMEOUT_ENV = "SECOND_BRAIN_MCP_SESSION_IDLE_SEC"


def resolve_idle_timeout(
    env: dict[str, str] | None = None,
    default: float = DEFAULT_SESSION_IDLE_TIMEOUT_SEC,
) -> float | None:
    """Вернуть таймаут простоя сессии из окружения.

    Args:
        env: Словарь окружения (по умолчанию ``os.environ``).
        default: Значение, если переменная не задана.

    Returns:
        Секунды простоя или ``None``, если предохранитель выключен
        (пустая строка, ``0`` или нечисловое значение).
    """
    source = os.environ if env is None else env
    raw = source.get(IDLE_TIMEOUT_ENV)
    if raw is None:
        return default
    raw = raw.strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        logger.warning(
            "%s=%r -- не число, предохранитель сессий выключен", IDLE_TIMEOUT_ENV, raw
        )
        return None
    return value if value > 0 else None


def find_session_managers(app: Any) -> list[Any]:
    """Найти менеджеры сессий в дереве маршрутов ASGI-приложения.

    Обёртка транспорта хранит менеджер в атрибуте ``session_manager``; в
    зависимости от того, включена ли в FastMCP своя авторизация, она лежит либо
    прямо в ``route.endpoint``, либо под слоем middleware (атрибут ``app``).

    Args:
        app: Starlette-приложение, собранное FastMCP.

    Returns:
        Список найденных менеджеров (обычно ноль или один).
    """
    found: list[Any] = []
    for route in getattr(app, "routes", None) or []:
        node = getattr(route, "endpoint", None) or getattr(route, "app", None)
        seen: set[int] = set()
        # Разворачиваем цепочку middleware, но не больше разумного и без циклов.
        while node is not None and id(node) not in seen and len(seen) < 16:
            seen.add(id(node))
            manager = getattr(node, "session_manager", None)
            if manager is not None:
                found.append(manager)
                break
            node = getattr(node, "app", None)
    return found


def apply_session_idle_timeout(app: Any, timeout_sec: float | None) -> int:
    """Проставить таймаут простоя всем менеджерам сессий приложения.

    Значение читается менеджером на каждом запросе, поэтому его допустимо
    выставлять уже после сборки приложения.

    Args:
        app: Starlette-приложение, собранное FastMCP.
        timeout_sec: Секунды простоя; ``None`` -- ничего не делать.

    Returns:
        Сколько менеджеров удалось настроить.
    """
    if timeout_sec is None:
        logger.info("Протухание MCP-сессий выключено (%s)", IDLE_TIMEOUT_ENV)
        return 0

    managers = find_session_managers(app)
    if not managers:
        logger.warning(
            "Менеджер MCP-сессий не найден в маршрутах -- брошенные сессии не "
            "будут протухать (проверьте версию FastMCP)"
        )
        return 0

    for manager in managers:
        manager.session_idle_timeout = timeout_sec
    logger.info(
        "Брошенные MCP-сессии протухают через %.0f с (менеджеров: %d)",
        timeout_sec,
        len(managers),
    )
    return len(managers)


class _SelfPruningSessions(dict):
    """Реестр сессий, из которого закрытые вычищаются при добавлении новой.

    ЗАЧЕМ: ``StreamableHTTPServerTransport.terminate()`` закрывает потоки и
    ставит флаг ``_terminated``, но НЕ убирает себя из ``_server_instances``
    менеджера, а блок очистки в менеджере пропускает удаление именно для
    терминированных (``... and not http_transport.is_terminated``). То есть
    каждая КОРРЕКТНО закрытая сессия остаётся в словаре навсегда.

    Замер 2026-09-02: 50 открытых и закрытых сессий -> 50 записей в реестре,
    все с ``is_terminated=True``; на живом memory_router это ~5.2 КБ на
    сессию. Поллер задач открывает сессию каждые 5 секунд на агента -- около
    34 тысяч сессий в сутки, порядка 180 МБ. Это и есть тот линейный рост,
    который держался после починки протухания брошенных сессий: тот
    предохранитель убирает сессии, которые клиент не закрыл, а здесь течёт
    ровно противоположный случай -- закрытые по правилам.

    Поведение не меняется: запрос со ссылкой на удалённую сессию получает
    тот же 404 ``Session not found``, только из ветки менеджера про
    неизвестный идентификатор, а не из проверки ``_terminated``.

    Чистка навешена на вставку, а не на фоновую задачу: вставка происходит
    под ``_session_creation_lock`` менеджера, отдельного жизненного цикла не
    требует, а размер словаря после чистки равен числу живых сессий.
    """

    def __setitem__(self, key: str, value: Any) -> None:
        """Добавить сессию, попутно выбросив все уже закрытые."""
        dead = [k for k, v in self.items() if getattr(v, "is_terminated", False)]
        for k in dead:
            super().__delitem__(k)
        if dead:
            logger.debug("Выброшено закрытых MCP-сессий из реестра: %d", len(dead))
        super().__setitem__(key, value)


def install_session_registry_pruning(app: Any) -> int:
    """Заменить реестры сессий на самоочищающиеся.

    Args:
        app: Starlette-приложение, собранное FastMCP.

    Returns:
        Сколько менеджеров удалось починить.
    """
    patched = 0
    for manager in find_session_managers(app):
        current = getattr(manager, "_server_instances", None)
        if current is None or isinstance(current, _SelfPruningSessions):
            continue
        manager._server_instances = _SelfPruningSessions(current)
        patched += 1
    if not patched:
        logger.warning(
            "Реестр MCP-сессий не подменён -- закрытые сессии будут "
            "накапливаться (проверьте версию MCP SDK)"
        )
    else:
        logger.info("Закрытые MCP-сессии вычищаются из реестра (менеджеров: %d)", patched)
    return patched


def build_http_app(mcp: Any, timeout_sec: float | None | str = "auto") -> Any:
    """Собрать HTTP-приложение MCP и включить протухание брошенных сессий.

    Замена прямому вызову ``mcp.http_app(transport="streamable-http")``.

    Args:
        mcp: Экземпляр FastMCP.
        timeout_sec: Секунды простоя; ``"auto"`` -- взять из окружения,
            ``None`` -- не включать предохранитель.

    Returns:
        ASGI-приложение Starlette.
    """
    app = mcp.http_app(transport="streamable-http")
    resolved = resolve_idle_timeout() if timeout_sec == "auto" else timeout_sec
    apply_session_idle_timeout(app, resolved)  # type: ignore[arg-type]
    # Два разных случая, и предохранители нужны оба: таймаут выше убирает
    # сессии, которые клиент бросил, а здесь -- те, что он закрыл по правилам.
    install_session_registry_pruning(app)
    return app
