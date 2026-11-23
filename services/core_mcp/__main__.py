"""Combined second_brain MCP process.

Runs the three light, model-free MCP servers — memory (5001), swarm (5000),
task (5003) — in ONE process / event loop instead of three. They already share
the asyncpg pool (the ``get_pool`` singleton in ``services.shared.db``), so a
single process simply drops two redundant Python interpreters + import sets
(~170 MB RAM on the 8 GB box).

recall (5002) deliberately stays a SEPARATE service: it loads the e5 + reranker
models (~2.2 GB) and must be isolated so a write-path fault here can never
OOM-kill the search hot path.

Ports are unchanged, so agent ``.mcp.json`` configs need no edit. Each port can
be overridden with its canonical env var (``MCP_MEMORY_PORT``,
``MCP_AGENT_ROUTER_PORT``, ``MCP_TASK_PORT``, see ``.env.example``); unset or
empty means the module's ``DEFAULT_PORT``.
"""
import asyncio
import logging
import os
from collections.abc import Mapping
from types import ModuleType

import uvicorn

from services.memory_mcp import server as memory_server
from services.agent_router_mcp import server as agent_router_server
from services.task_mcp import server as task_server
from services.shared.logging_setup import configure_logging, uvicorn_log_level
from services.shared.mcp_http import build_http_app

logger = logging.getLogger("second_brain-core-mcp")

# (label, module, port). Each module exposes `mcp` (FastMCP) + its own
# `AuthCaptureMiddleware`; tools are registered at import time.
_SERVICES: list[tuple[str, ModuleType, int]] = [
    ("memory", memory_server, memory_server.DEFAULT_PORT),
    ("agent_router", agent_router_server, agent_router_server.DEFAULT_PORT),
    ("task", task_server, task_server.DEFAULT_PORT),
]

# Переменная окружения с портом для каждого сервиса. Имена — канонические из
# .env.example (их же проверяет sanitize-check). Раньше порты брались только из
# DEFAULT_PORT, и поднять core на других портах (песочница, второй стенд на той
# же машине) было нельзя без подмены _SERVICES снаружи.
_PORT_ENV: dict[str, str] = {
    "memory": "MCP_MEMORY_PORT",
    "agent_router": "MCP_AGENT_ROUTER_PORT",
    "task": "MCP_TASK_PORT",
}


def _resolve_services(
    services: list[tuple[str, ModuleType, int]],
    environ: Mapping[str, str],
) -> list[tuple[str, ModuleType, int]]:
    """Apply per-service port overrides from the environment.

    Args:
        services: ``(label, module, default_port)`` triples.
        environ: Environment to read overrides from (usually ``os.environ``).

    Returns:
        The same triples with ports replaced where the service's env var is set
        to a non-empty value; other entries keep their default port.

    Raises:
        ValueError: If an override is not an integer.
    """
    resolved: list[tuple[str, ModuleType, int]] = []
    for label, mod, default_port in services:
        env_name = _PORT_ENV.get(label)
        raw = environ.get(env_name, "").strip() if env_name else ""
        port = int(raw) if raw else default_port
        resolved.append((label, mod, port))
    return resolved


async def _serve_all() -> None:
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    services = _resolve_services(_SERVICES, os.environ)
    servers = []
    for _label, mod, port in services:
        # build_http_app вместо mcp.http_app: включает протухание брошенных
        # MCP-сессий, иначе они копятся на сервере до перезапуска.
        app = mod.AuthCaptureMiddleware(build_http_app(mod.mcp))
        cfg = uvicorn.Config(app, host=host, port=port, log_level=uvicorn_log_level())
        servers.append(uvicorn.Server(cfg))
    logger.info(
        "second_brain-core-mcp: serving %s in one process",
        " ".join(f"{lbl}:{p}" for lbl, _m, p in services),
    )
    # Each app carries its own FastMCP lifespan (pool init / swarm recovery /
    # task supervisor); the shared pool singleton means only the first opens it.
    await asyncio.gather(*(s.serve() for s in servers))


def main() -> None:
    configure_logging()
    asyncio.run(_serve_all())


if __name__ == "__main__":
    main()
