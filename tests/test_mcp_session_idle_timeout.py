"""Тесты предохранителя от накопления брошенных MCP-сессий.

Регрессия 2026-09-01: FastMCP собирает StreamableHTTPSessionManager без
session_idle_timeout, брошенные сессии живут вечно и memory_router вырос до
4.9 ГБ. Хелпер services.shared.mcp_http проставляет таймаут после сборки
приложения; здесь проверяем, что он находит менеджер в реальной раскладке
маршрутов FastMCP и не роняет процесс, когда не нашёл.
"""

import logging

import pytest

from services.shared.mcp_http import (
    DEFAULT_SESSION_IDLE_TIMEOUT_SEC,
    IDLE_TIMEOUT_ENV,
    _SelfPruningSessions,
    apply_session_idle_timeout,
    build_http_app,
    find_session_managers,
    install_session_registry_pruning,
    resolve_idle_timeout,
)


class _Manager:
    """Заглушка менеджера сессий."""

    def __init__(self) -> None:
        self.session_idle_timeout = None


class _Endpoint:
    """Заглушка ASGI-обёртки транспорта."""

    def __init__(self, manager: _Manager) -> None:
        self.session_manager = manager


class _Route:
    def __init__(self, endpoint: object) -> None:
        self.endpoint = endpoint


class _App:
    def __init__(self, routes: list[object]) -> None:
        self.routes = routes


class _Middleware:
    """Слой, прячущий обёртку транспорта под атрибутом app."""

    def __init__(self, app: object) -> None:
        self.app = app


def test_resolve_idle_timeout_defaults_when_unset() -> None:
    assert resolve_idle_timeout(env={}) == DEFAULT_SESSION_IDLE_TIMEOUT_SEC


@pytest.mark.parametrize("raw", ["", "   ", "0", "-5", "нет"])
def test_resolve_idle_timeout_disabled(raw: str) -> None:
    assert resolve_idle_timeout(env={IDLE_TIMEOUT_ENV: raw}) is None


def test_resolve_idle_timeout_reads_env() -> None:
    assert resolve_idle_timeout(env={IDLE_TIMEOUT_ENV: "900"}) == 900.0


def test_find_session_manager_direct_and_under_middleware() -> None:
    direct, wrapped = _Manager(), _Manager()
    app = _App([_Route(_Endpoint(direct)), _Route(_Middleware(_Endpoint(wrapped)))])
    assert find_session_managers(app) == [direct, wrapped]


def test_find_session_manager_tolerates_odd_routes() -> None:
    app = _App([_Route(None), object(), _Route(_Middleware(_Middleware(object())))])
    assert find_session_managers(app) == []


def test_apply_sets_timeout_on_every_manager() -> None:
    managers = [_Manager(), _Manager()]
    app = _App([_Route(_Endpoint(m)) for m in managers])
    assert apply_session_idle_timeout(app, 1800.0) == 2
    assert [m.session_idle_timeout for m in managers] == [1800.0, 1800.0]


def test_apply_none_leaves_manager_untouched() -> None:
    manager = _Manager()
    app = _App([_Route(_Endpoint(manager))])
    assert apply_session_idle_timeout(app, None) == 0
    assert manager.session_idle_timeout is None


def test_apply_warns_but_does_not_raise_when_manager_missing(
    caplog: pytest.LogCaptureFixture,
) -> None:
    with caplog.at_level(logging.WARNING):
        assert apply_session_idle_timeout(_App([]), 1800.0) == 0
    assert any(r.levelno == logging.WARNING for r in caplog.records)


def test_build_http_app_sets_timeout_on_real_fastmcp_app() -> None:
    """Главная проверка: менеджер находится в НАСТОЯЩЕЙ раскладке FastMCP."""
    fastmcp = pytest.importorskip("fastmcp")
    mcp = fastmcp.FastMCP("test-idle-timeout")
    app = build_http_app(mcp, timeout_sec=1800.0)
    managers = find_session_managers(app)
    assert managers, "менеджер сессий не найден — раскладка FastMCP изменилась"
    assert all(m.session_idle_timeout == 1800.0 for m in managers)


def test_session_manager_reads_timeout_per_request() -> None:
    """Значение должно читаться на каждом запросе, иначе поздняя правка бесполезна."""
    pytest.importorskip("mcp")
    import inspect

    from mcp.server.streamable_http_manager import StreamableHTTPSessionManager

    source = inspect.getsource(StreamableHTTPSessionManager)
    assert source.count("self.session_idle_timeout") >= 2


class _Transport:
    """Заглушка транспорта: важен только флаг закрытия."""

    def __init__(self, terminated: bool) -> None:
        self.is_terminated = terminated


def test_pruning_registry_drops_closed_sessions_on_insert() -> None:
    """Закрытые сессии не должны переживать добавление следующей."""
    registry = _SelfPruningSessions()
    registry["a"] = _Transport(terminated=True)
    registry["b"] = _Transport(terminated=False)
    registry["c"] = _Transport(terminated=False)

    # "a" закрыта -- её выбросило при вставке "b"; живые остались.
    assert set(registry) == {"b", "c"}


def test_pruning_registry_keeps_live_sessions() -> None:
    """Живые сессии не трогаем, иначе оборвём работающих клиентов."""
    registry = _SelfPruningSessions()
    for name in ("a", "b", "c"):
        registry[name] = _Transport(terminated=False)
    assert set(registry) == {"a", "b", "c"}


def test_pruning_registry_tolerates_objects_without_the_flag() -> None:
    """Чужой объект без is_terminated считаем живым, а не мусором."""
    registry = _SelfPruningSessions()
    registry["a"] = object()
    registry["b"] = _Transport(terminated=False)
    assert set(registry) == {"a", "b"}


def test_install_pruning_replaces_registry_and_is_idempotent() -> None:
    """Повторная установка не оборачивает реестр второй раз."""
    manager = _Manager()
    manager._server_instances = {"old": _Transport(terminated=False)}
    app = _App([_Route(_Endpoint(manager))])

    assert install_session_registry_pruning(app) == 1
    assert isinstance(manager._server_instances, _SelfPruningSessions)
    # Существующие записи переносятся, а не теряются.
    assert set(manager._server_instances) == {"old"}
    assert install_session_registry_pruning(app) == 0


def test_install_pruning_warns_but_does_not_raise_when_manager_missing(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Смена раскладки FastMCP не должна ронять сервис на старте."""
    with caplog.at_level(logging.WARNING):
        assert install_session_registry_pruning(_App([])) == 0
    assert any("реестр" in r.message.lower() for r in caplog.records)


def test_build_http_app_installs_pruning_on_real_fastmcp_app() -> None:
    """Главная проверка: подмена садится на НАСТОЯЩУЮ раскладку FastMCP."""
    fastmcp = pytest.importorskip("fastmcp")
    mcp = fastmcp.FastMCP("test-session-pruning")
    app = build_http_app(mcp, timeout_sec=1800.0)
    managers = find_session_managers(app)
    assert managers, "менеджер сессий не найден — раскладка FastMCP изменилась"
    assert all(isinstance(m._server_instances, _SelfPruningSessions) for m in managers)


def test_sdk_still_leaves_closed_sessions_behind() -> None:
    """Сторож апстрима: когда SDK починят, обходной путь пора снимать.

    Блок очистки менеджера пропускает удаление именно для терминированных
    (``and not http_transport.is_terminated``), а ``terminate()`` себя из
    реестра не убирает. Если эта строка из SDK исчезнет -- проверить, не стал
    ли наш реестр лишним.
    """
    pytest.importorskip("mcp")
    import inspect

    from mcp.server.streamable_http_manager import StreamableHTTPSessionManager

    source = inspect.getsource(StreamableHTTPSessionManager)
    assert "not http_transport.is_terminated" in source
