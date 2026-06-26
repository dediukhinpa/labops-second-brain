"""Bearer-token auth cache: authenticate() memoizes the agent_tokens lookup.

The Bearer lookup was hitting the DB on every MCP call. agent_tokens has ~11
rows and changes rarely, so a short-TTL in-process cache removes a round-trip
from the hot path. Only successful lookups are cached; failures and revocations
re-check (revocation lag bounded by the TTL).
"""
import time

from services.shared.auth import (
    _AUTH_CACHE,
    _AUTH_CACHE_TTL,
    AgentContext,
    authenticate,
)


class _FakePool:
    """Counts fetchrow calls; returns a fixed row (or None)."""

    def __init__(self, row):
        self._row = row
        self.calls = 0

    async def fetchrow(self, *args, **kwargs):
        self.calls += 1
        return self._row


_ROW = {
    "agent": "christopher",
    "can_write_scopes": ["decisions"],
    "can_read_scopes": ["*"],
}


async def test_authenticate_caches_within_ttl():
    _AUTH_CACHE.clear()
    pool = _FakePool(_ROW)
    c1 = await authenticate("tok-A", pool)
    c2 = await authenticate("tok-A", pool)
    assert pool.calls == 1                       # second call served from cache
    assert isinstance(c1, AgentContext)
    assert c1.agent == c2.agent == "christopher"
    assert c2.read_scopes == ["*"]
    assert c2.write_scopes == ["decisions"]


async def test_authenticate_distinct_tokens_each_query():
    _AUTH_CACHE.clear()
    pool = _FakePool(_ROW)
    await authenticate("tok-A", pool)
    await authenticate("tok-B", pool)
    assert pool.calls == 2                        # different hashes -> separate lookups


async def test_authenticate_expired_entry_refetches():
    _AUTH_CACHE.clear()
    pool = _FakePool(_ROW)
    await authenticate("tok-A", pool)
    # Force-expire the single cached entry.
    (h, (_exp, ctx)), = _AUTH_CACHE.items()
    _AUTH_CACHE[h] = (time.monotonic() - 1.0, ctx)
    await authenticate("tok-A", pool)
    assert pool.calls == 2                        # expired -> re-queried


async def test_authenticate_does_not_cache_failure():
    _AUTH_CACHE.clear()
    pool = _FakePool(None)
    try:
        await authenticate("bad-token", pool)
        assert False, "expected PermissionError"
    except PermissionError:
        pass
    assert len(_AUTH_CACHE) == 0                   # failures are never cached
    _AUTH_CACHE.clear()
