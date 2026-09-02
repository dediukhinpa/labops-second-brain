"""Загрузка модели эмбеддингов, в том числе квантованного ONNX-варианта.

Замер 2026-09-02 на этом VPS (paraphrase-multilingual-mpnet-base-v2):

    вариант   резидент   пачка 32   одиночный запрос
    fp32       1435 МБ     5.1 с        ~50 мс
    int8        643 МБ     2.0 с         15 мс

Размерность у обоих 768, схема БД не меняется. Косинус int8-вектора к fp32 --
0.9945, но при смене варианта вайт всё равно переиндексируется, чтобы индекс
и запросы считались одной и той же моделью.

Тот же приём уже применён к реранкеру в ``memory_router_mcp.server``; здесь он
вынесен в общий модуль, потому что модель поднимают два сервиса.
"""

import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Полные веса: для них никакой регистрации варианта не нужно.
FULL_ONNX_FILE = "onnx/model.onnx"

# Файлы, которые fastembed ждёт рядом с весами. Он тянет их сам только для
# зарегистрированной модели; для нашего варианта их надо дозакачать явно.
TOKENIZER_FILES = (
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
)


def _pooling_and_normalization(model_name: str) -> tuple[Any, bool]:
    """Определить пулинг и нормализацию базовой модели.

    Вариант обязан считать вектор так же, как полные веса, иначе он окажется
    несовместим с уже посчитанным индексом. Спрашиваем сам fastembed, какой
    внутренний класс обслуживает модель, вместо того чтобы угадывать.

    Args:
        model_name: Имя модели в реестре fastembed.

    Returns:
        Пара (тип пулинга, нужна ли нормализация).

    Raises:
        ValueError: Класс модели неизвестен -- вариант собирать нельзя.
    """
    from fastembed.common.model_description import PoolingType
    from fastembed.text.text_embedding import TextEmbedding

    by_class = {
        "PooledEmbedding": (PoolingType.MEAN, False),
        "PooledNormalizedEmbedding": (PoolingType.MEAN, True),
        "OnnxTextEmbedding": (PoolingType.CLS, True),
    }
    for cls in TextEmbedding.EMBEDDINGS_REGISTRY:
        try:
            names = [d.model for d in cls._list_supported_models()]
        except Exception:  # noqa: BLE001 -- реестр может быть неполным
            continue
        if model_name in names:
            if cls.__name__ not in by_class:
                raise ValueError(
                    f"модель {model_name} обслуживается классом {cls.__name__}, "
                    "правила пулинга для него неизвестны"
                )
            return by_class[cls.__name__]
    raise ValueError(f"модель {model_name} не найдена в реестре fastembed")


def _base_description(model_name: str) -> Any:
    """Найти описание базовой модели в реестре fastembed."""
    from fastembed import TextEmbedding

    for desc in TextEmbedding._list_supported_models():
        if desc.model == model_name:
            return desc
    raise ValueError(f"модель {model_name} не найдена в реестре fastembed")


def _register_variant(model_name: str, onnx_file: str, cache_dir: str | None) -> str:
    """Зарегистрировать квантованный вариант модели и подтянуть его файлы.

    Args:
        model_name: Базовая модель из реестра fastembed.
        onnx_file: Путь к весам внутри репозитория модели.
        cache_dir: Каталог кэша весов.

    Returns:
        Имя, под которым вариант зарегистрирован.
    """
    from fastembed import TextEmbedding
    from fastembed.common.model_description import ModelSource
    from huggingface_hub import hf_hub_download

    desc = _base_description(model_name)
    pooling, normalization = _pooling_and_normalization(model_name)
    hf_repo = desc.sources.hf
    if not hf_repo:
        raise ValueError(f"у модели {model_name} нет HF-источника")

    variant = f"{model_name}-{Path(onnx_file).stem}"
    try:
        TextEmbedding.add_custom_model(
            model=variant,
            pooling=pooling,
            normalization=normalization,
            sources=ModelSource(hf=hf_repo),
            dim=desc.dim,
            model_file=onnx_file,
            description=f"{model_name} ({onnx_file})",
            license=desc.license,
        )
    except Exception:  # noqa: BLE001 -- уже зарегистрирован в этом процессе
        logger.debug("вариант %s уже зарегистрирован", variant)

    if cache_dir:
        # Регистрация не скачивает ничего: fastembed переиспользует снапшот
        # базовой модели и сам за другим файлом весов не пойдёт.
        for name in (onnx_file, *TOKENIZER_FILES):
            hf_hub_download(hf_repo, name, cache_dir=cache_dir)
    return variant


def load_text_embedding(
    model_name: str, onnx_file: str | None, cache_dir: str | None
) -> Any:
    """Поднять модель эмбеддингов, при необходимости квантованный вариант.

    Отказ варианта не должен ронять сервис: он деградирует к полным весам,
    которые заведомо есть в реестре. Разница только в памяти и скорости --
    вектор остаётся сопоставимым.

    Args:
        model_name: Имя модели в реестре fastembed.
        onnx_file: Путь к весам внутри репозитория модели; ``onnx/model.onnx``
            или пусто -- брать полные веса.
        cache_dir: Каталог кэша весов.

    Returns:
        Готовый объект ``TextEmbedding``.
    """
    from fastembed import TextEmbedding

    if not onnx_file or onnx_file == FULL_ONNX_FILE:
        return TextEmbedding(model_name, cache_dir=cache_dir)

    try:
        variant = _register_variant(model_name, onnx_file, cache_dir)
        model = TextEmbedding(variant, cache_dir=cache_dir)
        logger.info("модель эмбеддингов поднята из варианта %s", onnx_file)
        return model
    except Exception:
        logger.exception(
            "вариант %s не поднялся, беру полные веса -- это дороже по памяти",
            onnx_file,
        )
        return TextEmbedding(model_name, cache_dir=cache_dir)
