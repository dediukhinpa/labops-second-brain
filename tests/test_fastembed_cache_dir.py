"""Каталог весов FastEmbed должен передаваться явно, а не через окружение.

Замер 2026-09-02 на живом хосте: юниты выставляют ``FASTEMBED_CACHE_DIR``,
но fastembed 0.8.0 читает ``FASTEMBED_CACHE_PATH`` -- и без явного аргумента
уходит в ``tempfile.gettempdir()/fastembed_cache``. Под systemd с
``PrivateTmp=yes`` это приватный tmpfs, который стирается на каждом рестарте:
сервис заново тянул ~1.1 ГБ с HuggingFace и держал их в оперативке вместо
диска, а кэш на диске так и оставался пустым.
"""

import os
from pathlib import Path

import pytest

import services.ingest_worker.embedder as embedder_module
from services.ingest_worker.embedder import Embedder
from services.shared.config import Config


class _FakeVector:
    def __init__(self, values: list[float]) -> None:
        self._values = values

    def tolist(self) -> list[float]:
        return list(self._values)


class _RecordingModel:
    """Запоминает аргументы, с которыми её создали."""

    last_kwargs: dict[str, object] = {}

    def __init__(self, model_name: str, cache_dir: str | None = None) -> None:
        type(self).last_kwargs = {"model_name": model_name, "cache_dir": cache_dir}

    def embed(self, batch: list[str]) -> list[_FakeVector]:
        return [_FakeVector([1.0]) for _ in batch]


def _record_loader(monkeypatch) -> dict[str, object]:
    """Подменить загрузчик модели и вернуть словарь с его аргументами."""
    seen: dict[str, object] = {}

    def fake_loader(model_name: str, onnx_file: str | None, cache_dir: str | None):
        seen.update(
            {"model_name": model_name, "onnx_file": onnx_file, "cache_dir": cache_dir}
        )
        return _RecordingModel(model_name, cache_dir)

    monkeypatch.setattr(embedder_module, "load_text_embedding", fake_loader)
    return seen


def test_embedder_passes_cache_dir_to_loader(monkeypatch) -> None:
    seen = _record_loader(monkeypatch)

    emb = Embedder(model_name="fake/model", cache_dir="/var/lib/second_brain/fastembed")
    emb.embed(["проверка"])

    assert seen["cache_dir"] == "/var/lib/second_brain/fastembed"


def test_embedder_without_cache_dir_passes_none(monkeypatch) -> None:
    seen = _record_loader(monkeypatch)

    Embedder(model_name="fake/model").embed(["проверка"])

    assert seen["cache_dir"] is None


def test_embedder_passes_the_onnx_variant(monkeypatch) -> None:
    seen = _record_loader(monkeypatch)

    Embedder(
        model_name="fake/model",
        cache_dir="/cache",
        onnx_file="onnx/model_quantized.onnx",
    ).embed(["проверка"])

    assert seen["onnx_file"] == "onnx/model_quantized.onnx"


def test_config_reads_cache_dir_from_env(monkeypatch) -> None:
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.setenv("FASTEMBED_CACHE_DIR", "/var/lib/second_brain/fastembed")

    assert Config().fastembed_cache_dir == "/var/lib/second_brain/fastembed"


def test_config_cache_dir_is_none_when_unset(monkeypatch) -> None:
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.delenv("FASTEMBED_CACHE_DIR", raising=False)

    assert Config().fastembed_cache_dir is None


def test_config_treats_empty_cache_dir_as_unset(monkeypatch) -> None:
    """Пустая переменная не должна превращаться в каталог "" -- fastembed
    создал бы кэш в рабочем каталоге сервиса."""
    monkeypatch.setenv("PG_PASSWORD", "test")
    monkeypatch.setenv("MCP_PORT", "5001")
    monkeypatch.setenv("FASTEMBED_CACHE_DIR", "")

    assert Config().fastembed_cache_dir is None


def test_fastembed_still_ignores_our_env_var(monkeypatch) -> None:
    """Сторожевой тест: если fastembed научится читать FASTEMBED_CACHE_DIR,
    этот тест упадёт и можно будет упростить проброс."""
    define_cache_dir = pytest.importorskip(
        "fastembed.common.utils", reason="fastembed не установлен"
    ).define_cache_dir

    monkeypatch.setenv("FASTEMBED_CACHE_DIR", "/nonexistent-on-purpose")
    monkeypatch.delenv("FASTEMBED_CACHE_PATH", raising=False)
    monkeypatch.setenv("TMPDIR", os.environ.get("TMPDIR", "/tmp"))

    resolved = define_cache_dir(None)

    assert Path("/nonexistent-on-purpose") != resolved
