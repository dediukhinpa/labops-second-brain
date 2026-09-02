"""Ingest worker -- polls embedding_jobs queue and processes documents."""
import asyncio
import hashlib
import json
import logging
import os
from pathlib import Path
import signal
import sys

import asyncpg

# Worker does not use MCP, but Config requires MCP_PORT.
os.environ.setdefault("MCP_PORT", "0")

from services.shared.config import Config  # noqa: E402
from services.shared.db import close_pool, get_pool  # noqa: E402

from .chunker import chunk_text  # noqa: E402
from .context import (  # noqa: E402
    build_context_prefix,
    contextualize_chunks,
    to_passage_inputs,
)
from .embedder import Embedder  # noqa: E402

logger = logging.getLogger(__name__)

POLL_BATCH_SIZE = 10
POLL_SLEEP_SEC = 5

# Порог, по которому файл в кэше считается весами модели, а не служебным
# json токенизатора: настоящие веса -- сотни мегабайт.
MODEL_WEIGHTS_MIN_BYTES = 10 * 1024 * 1024


def weights_are_cached_on_disk(cache_dir: str | None) -> bool:
    """Лежат ли веса модели на диске, чтобы их можно было перечитать.

    ЗАЧЕМ: выгрузка модели из памяти имеет смысл, только если следующая
    загрузка возьмёт веса с диска. Замер 2026-09-01 на живом хосте: в
    FASTEMBED_CACHE_DIR не было ни одного файла с весами -- работающие сервисы
    держали модель только в ОЗУ. В такой ситуации выгрузка превращает
    перезагрузку модели в скачивание с HuggingFace, а при недоступности сети --
    в отказ индексации. Поэтому без кэша на диске модель не отпускаем.

    Args:
        cache_dir: Каталог кэша FastEmbed; ``None`` или пусто -- считаем, что
            кэша нет.

    Returns:
        ``True``, если в каталоге нашёлся хотя бы один достаточно крупный файл.
    """
    if not cache_dir:
        return False
    root = Path(cache_dir)
    if not root.is_dir():
        return False
    for path in root.rglob("*"):
        try:
            if path.is_file() and path.stat().st_size >= MODEL_WEIGHTS_MIN_BYTES:
                return True
        except OSError:
            continue
    return False

SQL_FETCH_JOBS = """
    SELECT ej.id, ej.doc_id, d.body, d.path,
           d.source_type, d.agent, d.frontmatter
    FROM embedding_jobs ej
    JOIN documents d ON ej.doc_id = d.id
    WHERE ej.status = 'pending'
    ORDER BY ej.created_at
    LIMIT $1
    FOR UPDATE SKIP LOCKED
"""

SQL_UPDATE_STATUS = """
    UPDATE embedding_jobs
    SET status = $2, updated_at = now() AT TIME ZONE 'utc'
    WHERE id = $1
"""

# embedding_jobs.UNIQUE(doc_id, status) means re-embedding an already-completed
# doc (edit, or a model-change requeue) inserts a fresh 'pending' row that
# coexists fine -- until it reaches the SAME terminal status a prior job for
# that doc_id already holds, which then violates the constraint. Job history
# isn't needed past the current attempt, so the current job supersedes it:
# delete every other row for this doc_id right before recording our own status.
SQL_CLEAR_STALE_JOBS = """
    DELETE FROM embedding_jobs WHERE doc_id = $1 AND id <> $2
"""

SQL_DELETE_CHUNKS = """
    DELETE FROM chunks WHERE doc_id = $1
"""

SQL_INSERT_CHUNK = """
    INSERT INTO chunks (doc_id, position, content, chunk_hash, embedding, embedded_at)
    VALUES ($1, $2, $3, $4, $5::vector, now())
"""


def _vec_to_str(embedding: list[float]) -> str:
    """Convert embedding list to pgvector string format '[0.1,0.2,...]'."""
    return "[" + ",".join(str(v) for v in embedding) + "]"


class _ShutdownFlag:
    """Simple flag for graceful shutdown."""

    def __init__(self) -> None:
        self.requested: bool = False

    def set(self) -> None:
        self.requested = True


_shutdown = _ShutdownFlag()


def _handle_signal(sig: int, _frame: object) -> None:
    """Signal handler for SIGTERM/SIGINT."""
    logger.info("Received signal %d, requesting shutdown", sig)
    _shutdown.set()


def _parse_frontmatter(raw: object) -> dict:
    """Normalize a documents.frontmatter value to a dict.

    asyncpg returns ``jsonb`` as a JSON string (no codec configured), so accept
    str | dict | None and fail soft to ``{}`` on anything unparseable.
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw:
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except (ValueError, TypeError):
            return {}
    return {}


async def _process_job(
    conn: asyncpg.Connection,
    embedder: Embedder,
    job_id: int,
    doc_id: int,
    body: str,
    path: str,
    source_type: str | None = None,
    agent: str | None = None,
    frontmatter: object = None,
) -> None:
    """Process a single embedding job inside a transaction.

    Args:
        conn: Active asyncpg connection (within transaction).
        embedder: Embedder instance.
        job_id: Embedding job ID.
        doc_id: Document ID.
        body: Document body text.
        path: Document vault path (for logging).
        source_type: Document source_type (for the contextual prefix).
        agent: Authoring agent (for the contextual prefix).
        frontmatter: Document frontmatter jsonb (str|dict) for title/date/tags.
    """
    logger.info("Processing job %d (doc %d, path=%s)", job_id, doc_id, path)

    await conn.execute(SQL_UPDATE_STATUS, job_id, "processing")

    chunks = chunk_text(body)
    if not chunks:
        logger.warning("Job %d: empty body, marking completed", job_id)
        await conn.execute(SQL_UPDATE_STATUS, job_id, "completed")
        return

    # Contextual chunking: prepend a one-line document context to each chunk so
    # the embedding + FTS index situate it within the parent document.
    prefix = build_context_prefix(
        path=path,
        source_type=source_type,
        agent=agent,
        frontmatter=_parse_frontmatter(frontmatter),
        body=body,
    )
    chunks = contextualize_chunks(chunks, prefix)

    # Embed with the e5 "passage: " instruction prefix, but store the chunks
    # WITHOUT it: the prefix only steers the embedding, while `content` feeds
    # FTS + rerank and must stay clean.
    embeddings = embedder.embed(to_passage_inputs(chunks, embedder.uses_e5_prefix))

    await conn.execute(SQL_DELETE_CHUNKS, doc_id)

    for position, (chunk_text_str, embedding) in enumerate(
        zip(chunks, embeddings)
    ):
        chunk_hash = hashlib.sha256(chunk_text_str.encode("utf-8")).hexdigest()
        await conn.execute(
            SQL_INSERT_CHUNK,
            doc_id,
            position,
            chunk_text_str,
            chunk_hash,
            _vec_to_str(embedding),
        )

    await conn.execute(SQL_CLEAR_STALE_JOBS, doc_id, job_id)
    await conn.execute(SQL_UPDATE_STATUS, job_id, "completed")
    logger.info(
        "Job %d completed: %d chunks embedded for doc %d",
        job_id,
        len(chunks),
        doc_id,
    )


def model_is_idle_enough(
    model_loaded: bool, idle_seconds: float, idle_unload_sec: int
) -> bool:
    """Пора ли отпускать веса модели.

    Args:
        model_loaded: Загружена ли модель сейчас.
        idle_seconds: Сколько секунд она не использовалась.
        idle_unload_sec: Порог простоя; ``0`` -- выгрузка выключена.

    Returns:
        ``True``, если модель загружена и простаивает не меньше порога.
    """
    if idle_unload_sec <= 0 or not model_loaded:
        return False
    return idle_seconds >= idle_unload_sec


async def run_worker() -> None:
    """Main worker loop -- poll queue, process jobs, handle shutdown."""
    config = Config()
    pool = await get_pool(config)
    embedder = Embedder(
        model_name=config.fastembed_model,
        cache_dir=config.fastembed_cache_dir,
        onnx_file=config.fastembed_onnx_file,
    )
    idle_unload_sec = config.ingest_model_idle_unload_sec
    cache_dir = config.fastembed_cache_dir
    # Предупреждаем об отсутствующем кэше один раз, а не каждые пять секунд.
    cache_warning_shown = False

    logger.info("Ingest worker started, polling for jobs")

    try:
        while not _shutdown.requested:
            async with pool.acquire() as conn:
                async with conn.transaction():
                    rows = await conn.fetch(
                        SQL_FETCH_JOBS, POLL_BATCH_SIZE
                    )

                    if not rows:
                        pass  # sleep below
                    else:
                        for row in rows:
                            if _shutdown.requested:
                                logger.info(
                                    "Shutdown requested, stopping mid-batch"
                                )
                                break
                            sp = conn.transaction()
                            await sp.start()
                            try:
                                await _process_job(
                                    conn,
                                    embedder,
                                    row["id"],
                                    row["doc_id"],
                                    row["body"],
                                    row["path"],
                                    row["source_type"],
                                    row["agent"],
                                    row["frontmatter"],
                                )
                                await sp.commit()
                            except Exception:
                                logger.exception(
                                    "Job %d failed", row["id"]
                                )
                                await sp.rollback()
                                await conn.execute(
                                    SQL_CLEAR_STALE_JOBS, row["doc_id"], row["id"]
                                )
                                await conn.execute(
                                    SQL_UPDATE_STATUS,
                                    row["id"],
                                    "failed",
                                )

            if not rows and not _shutdown.requested:
                # Очередь пуста -- отпускаем веса модели (~1.4 ГБ анонимной
                # памяти на 8-гигабайтном хосте). Следующая задача поднимет их
                # заново: пауза на загрузку для фоновой индексации дешевле, чем
                # держать пятую часть ОЗУ занятой круглые сутки.
                if model_is_idle_enough(
                    embedder.model_loaded,
                    embedder.idle_seconds(),
                    idle_unload_sec,
                ):
                    if weights_are_cached_on_disk(cache_dir):
                        embedder.unload()
                    elif not cache_warning_shown:
                        logger.warning(
                            "Модель не выгружаю: в кэше %r нет весов, "
                            "перезагрузка потребовала бы скачивания",
                            cache_dir or "<не задан>",
                        )
                        cache_warning_shown = True
                await asyncio.sleep(POLL_SLEEP_SEC)

    finally:
        logger.info("Ingest worker shutting down")
        await close_pool()


def main() -> None:
    """Entry point for the ingest worker."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    asyncio.run(run_worker())


if __name__ == "__main__":
    main()
