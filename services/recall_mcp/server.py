"""FastMCP server for recall-mcp (read-side hybrid search), default port 8768.

Adopts the AuthCaptureMiddleware pattern from swarm-mcp and memory-mcp so all
three services have consistent identity surfacing. The recall tools require
token validation (Bearer or HMAC) and enforce ``agent_tokens.can_read_scopes``
per-call via :func:`services.recall_mcp.search._resolve_reader` and
``restrict_read_scopes`` / ``check_read_scope`` from :mod:`services.shared.auth`.
The middleware publishes the captured auth into a ContextVar
(``services.recall_mcp.search._REQUEST_AUTH``) which every tool body
consults.
"""
import logging
import os
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import asyncpg
from fastmcp import FastMCP

# Ensure parent package is importable when running as module
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.shared.asgi_auth import HermesAwareAuthMiddleware
from services.shared.config import Config
from services.shared.db import close_pool, get_pool

from .cache import RecallCache
from .search import _REQUEST_AUTH, register_tools

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

DEFAULT_PORT = 8768

_pool: asyncpg.Pool | None = None
_embed_model: Any = None
_reranker: Any = None
_cache: RecallCache = RecallCache()
_vault_root: Path = Path("/opt/second_brain/vault")

# Module-level config: read once so register_tools can see env-driven values.
# Lifespan() refreshes _vault_root from a fresh Config() at startup if the
# environment changes between import and run.
config = Config(mcp_port=int(os.environ.get("MCP_PORT", str(DEFAULT_PORT))))


def _load_reranker(base_model: str, onnx_file: str, cache_dir: str | None) -> Any:
    """Load a cross-encoder reranker, optionally a quantized ONNX variant.

    ``onnx_file == "onnx/model.onnx"`` loads the full registered model directly.
    Any other variant (e.g. ``onnx/model_int8.onnx``) is registered as a custom
    model over the same HF source and its specific ONNX file is fetched into the
    persistent cache before loading — the int8 variant fits alongside e5-large
    under the service memory cap where the full model OOMs.
    """
    from fastembed.rerank.cross_encoder import TextCrossEncoder

    if not onnx_file or onnx_file == "onnx/model.onnx":
        return TextCrossEncoder(model_name=base_model, cache_dir=cache_dir)

    from fastembed.common.model_description import ModelSource
    from huggingface_hub import hf_hub_download

    variant = f"{base_model}-{Path(onnx_file).stem}"
    try:
        TextCrossEncoder.add_custom_model(
            model=variant,
            sources=ModelSource(hf=base_model),
            model_file=onnx_file,
            description=f"{base_model} ({onnx_file})",
            license="cc-by-nc-4.0",
            size_in_gb=0.3,
        )
    except Exception:
        # Already registered (e.g. a prior load this process) -- safe to ignore.
        logger.debug("reranker variant %s already registered", variant)
    if cache_dir:
        # FastEmbed reuses an existing snapshot and won't fetch a new model_file
        # on its own; pull the specific variant explicitly into the same cache.
        hf_hub_download(base_model, onnx_file, cache_dir=cache_dir)
    return TextCrossEncoder(model_name=variant, cache_dir=cache_dir)


@asynccontextmanager
async def lifespan(server: FastMCP) -> AsyncIterator[dict[str, Any]]:
    """Initialize asyncpg pool and FastEmbed model on startup."""
    global _pool, _embed_model, _reranker, _vault_root

    config = Config(mcp_port=int(os.environ.get("MCP_PORT", str(DEFAULT_PORT))))
    _vault_root = Path(config.vault_root)

    logger.info("Starting recall-mcp: loading asyncpg pool")
    _pool = await get_pool(config)

    logger.info("Loading FastEmbed model: %s", config.fastembed_model)
    from fastembed import TextEmbedding
    _embed_model = TextEmbedding(config.fastembed_model)

    # Optional second-stage cross-encoder reranker. Best-effort: a load failure
    # degrades recall to first-stage fusion rather than blocking startup.
    if config.rerank_enabled:
        logger.info(
            "Loading reranker: %s (%s)", config.rerank_model, config.rerank_onnx_file
        )
        try:
            _reranker = _load_reranker(
                config.rerank_model,
                config.rerank_onnx_file,
                # TextCrossEncoder ignores FASTEMBED_CACHE_DIR (unlike TextEmbedding)
                # and defaults to /tmp (non-persistent); pin the service cache.
                os.environ.get("FASTEMBED_CACHE_DIR") or None,
            )
        except Exception:
            logger.exception(
                "reranker load failed; recall will run without reranking"
            )
            _reranker = None

    logger.info(
        "recall-mcp ready: port=%d embed=%s rerank=%s",
        config.mcp_port,
        config.fastembed_model,
        config.rerank_model if (config.rerank_enabled and _reranker) else "off",
    )

    try:
        yield {}
    finally:
        logger.info("Shutting down recall-mcp")
        _cache.invalidate_all()
        await close_pool()
        _pool = None
        _embed_model = None
        _reranker = None


def _get_pool() -> asyncpg.Pool:
    """Return the initialized asyncpg pool."""
    if _pool is None:
        raise RuntimeError("Pool not initialized -- server not started")
    return _pool


def _get_embed() -> Any:
    """Return the loaded FastEmbed model."""
    if _embed_model is None:
        raise RuntimeError("Embed model not loaded -- server not started")
    return _embed_model


def _get_reranker() -> Any:
    """Return the loaded cross-encoder reranker, or None if disabled/unavailable."""
    return _reranker


def _rerank_scorer(query: str, docs: list[str]) -> list[float]:
    """Adapt the cross-encoder to the ``(query, docs) -> [score]`` contract.

    Returns neutral zero scores if the model is absent (disabled or failed to
    load), so :func:`_rerank` preserves first-stage order instead of erroring.
    """
    model = _get_reranker()
    if model is None:
        return [0.0] * len(docs)
    return list(model.rerank(query, docs))


def _get_cache() -> RecallCache:
    """Return the recall cache instance."""
    return _cache


def _get_vault_root() -> Path:
    """Return the vault root path."""
    return _vault_root


mcp = FastMCP(
    "recall-mcp",
    lifespan=lifespan,
)

register_tools(
    mcp,
    _get_pool,
    _get_embed,
    _get_cache,
    _get_vault_root,
    tool_set=config.second_brain_tools,
    rrf_weight_bm25=config.rrf_weight_bm25,
    rrf_weight_vec=config.rrf_weight_vec,
    diversify_max=config.diversify_max,
    rerank_scorer=(_rerank_scorer if config.rerank_enabled else None),
    rerank_candidates=config.rerank_candidates,
    rerank_max_chars=config.rerank_max_chars,
)


class AuthCaptureMiddleware(HermesAwareAuthMiddleware):
    """ASGI middleware: capture Bearer or Hermes HMAC auth into ContextVar.

    Thin compatibility subclass over :class:`HermesAwareAuthMiddleware`
    that binds the recall-mcp ContextVar. Mirrors swarm-mcp and
    memory-mcp pattern for consistent identity surfacing across all
    three MCP services.
    """

    def __init__(self, app):
        super().__init__(app, _REQUEST_AUTH)


def main() -> None:
    """Entry point for recall-mcp server."""
    import uvicorn
    port = int(os.environ.get("MCP_PORT", str(DEFAULT_PORT)))
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    logger.info("Starting recall-mcp on %s:%d (with auth middleware)", host, port)
    app = mcp.http_app(transport="streamable-http")
    app = AuthCaptureMiddleware(app)
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
