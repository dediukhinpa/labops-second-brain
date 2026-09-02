"""Загрузка квантованного варианта весов.

Замер 2026-09-02: полные веса mpnet -- 1435 МБ резидента и ~50 мс на запрос,
int8 -- 643 МБ и 15 мс при той же размерности 768. Вариант обязан считать
вектор так же, как полные веса (тот же пулинг и нормализация), иначе он
окажется несовместим с уже посчитанным индексом.
"""

import pytest

import services.shared.embed_model as embed_model
from services.shared.embed_model import FULL_ONNX_FILE, load_text_embedding


class _FakeTextEmbedding:
    """Заглушка: запоминает, с какой моделью её создали."""

    created: list[str] = []
    last_cache_dir: str | None = None
    registered: list[dict] = []

    def __init__(self, model_name: str, cache_dir: str | None = None) -> None:
        type(self).created.append(model_name)
        type(self).last_cache_dir = cache_dir

    @classmethod
    def add_custom_model(cls, **kwargs: object) -> None:
        cls.registered.append(dict(kwargs))


@pytest.fixture(autouse=True)
def _reset() -> None:
    _FakeTextEmbedding.created = []
    _FakeTextEmbedding.registered = []


def test_full_weights_load_without_registering_a_variant(monkeypatch) -> None:
    monkeypatch.setattr(
        "fastembed.TextEmbedding", _FakeTextEmbedding, raising=False
    )
    load_text_embedding("some/model", FULL_ONNX_FILE, "/cache")

    assert _FakeTextEmbedding.created == ["some/model"]
    assert _FakeTextEmbedding.registered == []


def test_empty_onnx_file_means_full_weights(monkeypatch) -> None:
    monkeypatch.setattr(
        "fastembed.TextEmbedding", _FakeTextEmbedding, raising=False
    )
    load_text_embedding("some/model", None, "/cache")

    assert _FakeTextEmbedding.created == ["some/model"]


def test_broken_variant_degrades_to_full_weights(monkeypatch) -> None:
    """Отказ варианта не должен ронять сервис: recall важнее экономии памяти."""
    monkeypatch.setattr(
        "fastembed.TextEmbedding", _FakeTextEmbedding, raising=False
    )
    monkeypatch.setattr(
        embed_model,
        "_register_variant",
        lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("нет такого файла")),
    )

    load_text_embedding("some/model", "onnx/model_quantized.onnx", "/cache")

    assert _FakeTextEmbedding.created == ["some/model"]


def test_unknown_model_class_is_rejected(monkeypatch) -> None:
    """Незнакомый класс -- значит правила пулинга неизвестны; угадывать нельзя."""
    pytest.importorskip("fastembed")

    with pytest.raises(ValueError):
        embed_model._pooling_and_normalization("нет/такой/модели")


def test_pooling_matches_the_real_registry() -> None:
    """Для рабочей модели пулинг берётся из самого fastembed, а не угадывается."""
    fastembed = pytest.importorskip("fastembed")
    model_name = "sentence-transformers/paraphrase-multilingual-mpnet-base-v2"
    known = {d.model for d in fastembed.TextEmbedding._list_supported_models()}
    if model_name not in known:
        pytest.skip("модель отсутствует в этой сборке fastembed")

    pooling, normalization = embed_model._pooling_and_normalization(model_name)

    # PooledEmbedding: среднее по токенам, без нормализации -- проверено
    # сравнением длин векторов с полными весами (2.4640 против 2.4463).
    assert pooling.name == "MEAN"
    assert normalization is False


def test_config_default_is_the_quantized_variant(monkeypatch) -> None:
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.delenv("FASTEMBED_ONNX_FILE", raising=False)

    from services.shared.config import Config

    assert Config().fastembed_onnx_file == "onnx/model_quantized.onnx"


def test_config_allows_pinning_full_weights(monkeypatch) -> None:
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.setenv("FASTEMBED_ONNX_FILE", FULL_ONNX_FILE)

    from services.shared.config import Config

    assert Config().fastembed_onnx_file == FULL_ONNX_FILE


def test_full_weights_still_get_the_cache_dir(monkeypatch) -> None:
    """Каталог кэша обязан доходить и до полных весов -- иначе снова /tmp."""
    monkeypatch.setattr(
        "fastembed.TextEmbedding", _FakeTextEmbedding, raising=False
    )
    load_text_embedding("some/model", FULL_ONNX_FILE, "/var/lib/second_brain/fastembed")

    assert _FakeTextEmbedding.last_cache_dir == "/var/lib/second_brain/fastembed"
