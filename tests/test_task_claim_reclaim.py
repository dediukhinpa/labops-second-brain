"""Integration tests for the durable task queue: atomic claim + supervisor reclaim.

Gated by SECOND_BRAIN_TEST_INTEGRATION=1 (needs live Postgres). All rows created here
use created_by='zztest-queue' and are deleted in teardown, so the live swarm's
real tasks are never touched.
"""
from __future__ import annotations

import asyncio
import json

import pytest

from services.shared.config import Config
from services.shared.db import close_pool, get_pool
from services.task_mcp import store

pytestmark = pytest.mark.integration

TESTER = "zztest-queue"


async def _cleanup(pool):
    ids = await pool.fetch(
        "SELECT id FROM tasks WHERE created_by = $1", TESTER
    )
    for r in ids:
        await pool.execute("DELETE FROM task_history WHERE task_id = $1", r["id"])
    await pool.execute("DELETE FROM tasks WHERE created_by = $1", TESTER)
    await pool.execute("DELETE FROM agents WHERE agent_name LIKE 'zz%'")


def _run(coro):
    return asyncio.run(coro)


def test_claim_is_atomic_and_records_owner():
    async def go():
        pool = await get_pool(Config(mcp_port=0))
        try:
            await _cleanup(pool)
            t = await store.create_task(
                pool, agent=TESTER, title="claim me", description="x",
                priority="high",
            )
            claimed = await store.claim_task(pool, "silvio", task_id=t["id"])
            assert claimed is not None
            assert claimed["status"] == "progress"
            assert claimed["assignee"] == "silvio"
            meta = claimed.get("metadata") or {}
            assert "claimed_at" in meta            # lease timestamp recorded

            # Second claim of the same (now non-'new') task yields nothing.
            again = await store.claim_task(pool, "carmela", task_id=t["id"])
            assert again is None

            hist = await store.list_task_history(pool, t["id"])
            assert any(h["new_status"] == "progress" for h in hist)
        finally:
            await _cleanup(pool)
            await close_pool()
    _run(go())


def test_reclaim_requeues_dead_owner_but_spares_live_one():
    async def go():
        pool = await get_pool(Config(mcp_port=0))
        try:
            await _cleanup(pool)
            # Orphan: claimed by an agent with no heartbeat, claimed long ago.
            dead = await store.create_task(
                pool, agent=TESTER, title="orphan", description="x",
            )
            await store.claim_task(pool, "zzdead", task_id=dead["id"])
            # Backdate the lease so it is past any grace window.
            await pool.execute(
                "UPDATE tasks SET metadata = jsonb_set(metadata, '{claimed_at}',"
                " to_jsonb((now() - interval '1 hour')::text)) WHERE id = $1",
                dead["id"],
            )

            # Live: claimed by an agent heartbeating right now.
            live = await store.create_task(
                pool, agent=TESTER, title="busy", description="x",
            )
            await store.claim_task(pool, "zzlive", task_id=live["id"])
            await pool.execute(
                "INSERT INTO agents (agent_name, status, last_seen) "
                "VALUES ('zzlive','online', now()) "
                "ON CONFLICT (agent_name) DO UPDATE SET last_seen = now()",
            )

            reclaimed = await store.reclaim_orphaned_tasks(
                pool, stale_after_seconds=120, grace_seconds=60
            )
            assert dead["id"] in reclaimed
            assert live["id"] not in reclaimed

            d = await store.get_task(pool, dead["id"])
            assert d["status"] == "new"
            assert d["assignee"] is None
            lv = await store.get_task(pool, live["id"])
            assert lv["status"] == "progress"
        finally:
            await _cleanup(pool)
            await close_pool()
    _run(go())
