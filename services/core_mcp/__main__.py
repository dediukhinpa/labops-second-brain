"""Combined second_brain MCP process.

Runs the three light, model-free MCP servers — memory (8767), swarm (8766),
task (8769) — in ONE process / event loop instead of three. They already share
the asyncpg pool (the ``get_pool`` singleton in ``services.shared.db``), so a
single process simply drops two redundant Python interpreters + import sets
(~170 MB RAM on the 8 GB box).

recall (8768) deliberately stays a SEPARATE service: it loads the e5 + reranker
models (~2.2 GB) and must be isolated so a write-path fault here can never
OOM-kill the search hot path.

Ports are unchanged, so agent ``.mcp.json`` configs need no edit.
"""
import asyncio
import logging
import os

import uvicorn

from services.memory_mcp import server as memory_server
from services.swarm_mcp import server as swarm_server
from services.task_mcp import server as task_server

logger = logging.getLogger("second_brain-core-mcp")

# (label, module, port). Each module exposes `mcp` (FastMCP) + its own
# `AuthCaptureMiddleware`; tools are registered at import time.
_SERVICES = [
    ("memory", memory_server, memory_server.DEFAULT_PORT),
    ("swarm", swarm_server, swarm_server.DEFAULT_PORT),
    ("task", task_server, task_server.DEFAULT_PORT),
]


async def _serve_all() -> None:
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    servers = []
    for _label, mod, port in _SERVICES:
        app = mod.AuthCaptureMiddleware(
            mod.mcp.http_app(transport="streamable-http")
        )
        cfg = uvicorn.Config(app, host=host, port=port, log_level="info")
        servers.append(uvicorn.Server(cfg))
    logger.info(
        "second_brain-core-mcp: serving %s in one process",
        " ".join(f"{lbl}:{p}" for lbl, _m, p in _SERVICES),
    )
    # Each app carries its own FastMCP lifespan (pool init / swarm recovery /
    # task supervisor); the shared pool singleton means only the first opens it.
    await asyncio.gather(*(s.serve() for s in servers))


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(_serve_all())


if __name__ == "__main__":
    main()
