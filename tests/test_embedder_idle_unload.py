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

    def __init__(self, model_name: str, cache_dir: str | None = None) -> None:
        type(self).loads += 1
        self.model_name = model_name
        self.cache_dir = cache_dir

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


def test_weights_are_cached_detects_real_weights(tmp_path) -> None:
    from services.ingest_worker.worker import (
        MODEL_WEIGHTS_MIN_BYTES,
        weights_are_cached_on_disk,
    )

    model_dir = tmp_path / "models" / "mpnet"
    model_dir.mkdir(parents=True)
    (model_dir / "tokenizer.json").write_bytes(b"x" * 1024)
    # Только мелочь -- весов нет.
    assert weights_are_cached_on_disk(str(tmp_path)) is False

    (model_dir / "model.onnx").write_bytes(b"x" * MODEL_WEIGHTS_MIN_BYTES)
    assert weights_are_cached_on_disk(str(tmp_path)) is True


def test_weights_are_cached_handles_missing_or_unset_dir(tmp_path) -> None:
    from services.ingest_worker.worker import weights_are_cached_on_disk

    assert weights_are_cached_on_disk(None) is False
    assert weights_are_cached_on_disk("") is False
    assert weights_are_cached_on_disk(str(tmp_path / "нет-такого")) is False
    # Каталог есть, но пуст -- ровно случай живого хоста 2026-09-01.
    assert weights_are_cached_on_disk(str(tmp_path)) is False


def test_model_is_idle_enough_respects_threshold_and_switch() -> None:
    from services.ingest_worker.worker import model_is_idle_enough

    assert model_is_idle_enough(True, 900.0, 900) is True
    assert model_is_idle_enough(True, 899.0, 900) is False
    # Выгрузка выключена порогом 0 -- сколько бы модель ни простаивала.
    assert model_is_idle_enough(True, 10_000.0, 0) is False
    # Модель не загружена -- выгружать нечего.
    assert model_is_idle_enough(False, 10_000.0, 900) is False
