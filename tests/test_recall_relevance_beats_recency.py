"""Смысл запроса должен перевешивать свежесть заметки.

Замер 2026-09-02 на живом вайте: запрос дословно по заголовку заметки выдавал
её лишь пятой, а первыми шли свежие, но нерелевантные. Причина -- в формуле
``final = rrf * source_weight * temporal_decay`` (``search.py``): RRF с K=60
сжимал релевантность до 22% разброса по всему корпусу, тогда как затухание
давало 67%, а веса источников 100%. Возраст перебивал смысл всегда.

Тесты пиннят само свойство, а не конкретные числа: если кто-то вернёт широкое
затухание или большое K, они упадут.
"""

from services.memory_router_mcp.search import _RRF_K, _rrf_fuse
from services.memory_router_mcp.source_weights import SOURCE_WEIGHTS, temporal_decay

HOURS_FRESH = 1.0
HOURS_OLD = 44 * 24.0


def _final_score(vec_rank: int, source_type: str, hours_ago: float) -> float:
    """Итоговый балл по формуле из search.py для документа только в векторном потоке."""
    rrf = 1.0 / (_RRF_K + vec_rank)
    return rrf * SOURCE_WEIGHTS.get(source_type, 1.0) * temporal_decay(hours_ago)


def test_relevant_old_note_beats_irrelevant_fresh_one() -> None:
    """Наблюдённый случай: нужная заметка первая по смыслу, но ей 44 дня."""
    relevant_old = _final_score(vec_rank=1, source_type="decision", hours_ago=HOURS_OLD)
    irrelevant_fresh = _final_score(
        vec_rank=3, source_type="decision", hours_ago=HOURS_FRESH
    )

    assert relevant_old > irrelevant_fresh


def test_freshness_still_breaks_ties() -> None:
    """Свежесть остаётся тай-брейком между одинаково релевантными заметками."""
    fresh = _final_score(vec_rank=1, source_type="decision", hours_ago=HOURS_FRESH)
    old = _final_score(vec_rank=1, source_type="decision", hours_ago=HOURS_OLD)

    assert fresh > old


def test_decay_spread_stays_below_rank_spread() -> None:
    """Разброс затухания не должен превосходить разброс релевантности.

    Иначе множитель снова начнёт перебивать смысл -- ровно то, что чинили.
    """
    decay_spread = temporal_decay(0.0) / temporal_decay(HOURS_OLD)
    # Разброс рангов по корпусу: первое место против двадцатого.
    rank_spread = (1.0 / (_RRF_K + 1)) / (1.0 / (_RRF_K + 20))

    assert decay_spread < rank_spread


def test_source_weight_still_dominates_relevance() -> None:
    """Фиксируем как есть: веса источников не трогали, они остаются главными.

    error-pattern (3.0) против knowledge (1.0) -- разброс 200%, больше, чем даёт
    разброс рангов. Это редакционное решение о ценности типов заметок, а не
    дефект ранжирования, и меняется оно отдельно и владельцем.
    """
    best_match_low_weight = _final_score(
        vec_rank=1, source_type="knowledge", hours_ago=HOURS_FRESH
    )
    weak_match_high_weight = _final_score(
        vec_rank=15, source_type="error-pattern", hours_ago=HOURS_FRESH
    )

    assert weak_match_high_weight > best_match_low_weight


def test_rrf_fuse_uses_the_configured_k() -> None:
    """Слияние обязано считать по _RRF_K, а не по зашитому числу."""
    row = {
        "id": 1, "doc_id": 1, "content": "c", "path": "decisions/1.md",
        "source_type": "decision", "scope": "decisions", "updated_at": None,
    }
    merged = _rrf_fuse([row], [], vec_weight=0.6, fts_weight=0.4)

    assert merged[1]["rrf"] == 1.0 / (_RRF_K + 1)
