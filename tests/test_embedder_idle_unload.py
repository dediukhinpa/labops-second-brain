"""Тесты выгрузки простаивающей модели у ingest-воркера.

Замер 2026-09-01 на живом хосте: ingest_worker держал 1465 МБ резидента, из
них лишь 29 МБ file-backed -- то есть 1.4 ГБ анонимной памяти, которую ядро
может только вытеснить в swap, но не отбросить. Очередь при этом пуста
практически всегда. Модель должна отпускаться в простое и подниматься заново,
когда появилась работа.
"""

import services.ingest_worker.embedder as embedder_module
from services.ingest_worker.embedder import Embedder


class _FakeVector:
    """Минимальная замена numpy-вектору: нужен только .tolist()."""

    def __init__(self, values: list[float]) -> None:
        self._values = values

    def tolist(self) -> list[float]:
        return list(self._values)


class _FakeModel:
    """Заглушка FastEmbed: считает, сколько раз её загрузили."""

    loads = 0

    def __init__(self, model_name: str) -> None:
        type(self).loads += 1
        self.model_name = model_name

    def embed(self, batch: list[str]) -> list[_FakeVector]:
        return [_FakeVector([float(len(t))]) for t in batch]


def _make_embedder(monkeypatch) -> Embedder:
    _FakeModel.loads = 0
    monkeypatch.setattr(embedder_module, "TextEmbedding", _FakeModel)
    return Embedder(model_name="fake/model")


def test_model_is_not_loaded_before_first_real_work(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    assert emb.model_loaded is False
    assert _FakeModel.loads == 0


def test_unload_frees_the_model_and_reports_it(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    emb.embed(["привет"])
    assert emb.model_loaded is True
    assert emb.unload() is True
    assert emb.model_loaded is False
    # Повторная выгрузка -- не ошибка, просто нечего выгружать.
    assert emb.unload() is False


def test_unload_keeps_cache_so_reload_is_not_needed(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    first = emb.embed(["привет"])
    emb.unload()
    again = emb.embed(["привет"])
    assert again == first
    # Пачка целиком из кэша не должна тянуть веса обратно в память.
    assert _FakeModel.loads == 1
    assert emb.model_loaded is False


def test_new_work_reloads_the_model(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    emb.embed(["первый"])
    emb.unload()
    emb.embed(["второй"])
    assert _FakeModel.loads == 2
    assert emb.model_loaded is True


def test_idle_unload_waits_for_the_threshold(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    emb.embed(["привет"])
    monkeypatch.setattr(emb, "idle_seconds", lambda: 899.0)
    assert emb.unload_if_idle(900) is False
    assert emb.model_loaded is True
    monkeypatch.setattr(emb, "idle_seconds", lambda: 901.0)
    assert emb.unload_if_idle(900) is True
    assert emb.model_loaded is False


def test_idle_unload_disabled_by_zero(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    emb.embed(["привет"])
    monkeypatch.setattr(emb, "idle_seconds", lambda: 10_000.0)
    assert emb.unload_if_idle(0) is False
    assert emb.model_loaded is True


def test_idle_unload_on_unloaded_model_is_a_noop(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    assert emb.unload_if_idle(1) is False
    assert emb.idle_seconds() == 0.0


def test_idle_seconds_counts_from_last_model_use(monkeypatch) -> None:
    emb = _make_embedder(monkeypatch)
    clock = [1000.0]
    monkeypatch.setattr(embedder_module.time, "monotonic", lambda: clock[0])
    emb.embed(["привет"])
    clock[0] = 1300.0
    assert emb.idle_seconds() == 300.0


def test_config_exposes_the_idle_threshold(monkeypatch) -> None:
    from services.shared.config import Config

    # Config требует эти переменные для несвязанных полей.
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.delenv("INGEST_MODEL_IDLE_UNLOAD_SEC", raising=False)
    assert Config().ingest_model_idle_unload_sec == 900
    monkeypatch.setenv("INGEST_MODEL_IDLE_UNLOAD_SEC", "0")
    assert Config().ingest_model_idle_unload_sec == 0
