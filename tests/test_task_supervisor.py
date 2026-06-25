"""Tests for the durable-task-queue supervisor's orphan-detection predicate.

A task is "orphaned" when it sits in `progress` but its claimer is gone — the
agent died/hung (stale heartbeat in the agents table) or never owned it — past a
grace window. The supervisor requeues such tasks (progress -> new). The predicate
is pure (no DB) so the dangerous "which tasks to reclaim" decision is unit-tested
in isolation, never against the live swarm's real tasks.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from services.task_mcp.supervisor import is_orphaned

NOW = datetime(2026, 6, 24, 12, 0, 0, tzinfo=timezone.utc)
STALE = 120  # heartbeat older than this => agent considered dead
GRACE = 60   # don't touch tasks claimed within this window


def _task(status="progress", assignee="silvio", claimed_secs_ago=300):
    claimed_at = None if claimed_secs_ago is None else NOW - timedelta(seconds=claimed_secs_ago)
    return {"status": status, "assignee": assignee, "claimed_at": claimed_at}


def _agents(**last_seen_secs_ago):
    return {
        name: NOW - timedelta(seconds=secs)
        for name, secs in last_seen_secs_ago.items()
    }


def test_non_progress_task_never_orphaned():
    for st in ("new", "review", "done", "blocked"):
        assert is_orphaned(_task(status=st), _agents(silvio=9999), NOW, STALE, GRACE) is False


def test_recently_claimed_within_grace_not_orphaned():
    # Even with a dead assignee, a just-claimed task gets the grace window.
    t = _task(claimed_secs_ago=30)
    assert is_orphaned(t, _agents(silvio=9999), NOW, STALE, GRACE) is False


def test_progress_with_live_assignee_not_orphaned():
    t = _task(assignee="silvio", claimed_secs_ago=300)
    assert is_orphaned(t, _agents(silvio=10), NOW, STALE, GRACE) is False


def test_progress_with_stale_assignee_is_orphaned():
    t = _task(assignee="silvio", claimed_secs_ago=300)
    assert is_orphaned(t, _agents(silvio=999), NOW, STALE, GRACE) is True


def test_progress_with_no_assignee_past_grace_is_orphaned():
    t = _task(assignee=None, claimed_secs_ago=300)
    assert is_orphaned(t, _agents(), NOW, STALE, GRACE) is True


def test_progress_with_unknown_assignee_is_orphaned():
    # Assignee not present in the agents registry at all.
    t = _task(assignee="ghost", claimed_secs_ago=300)
    assert is_orphaned(t, _agents(silvio=10), NOW, STALE, GRACE) is True


def test_legacy_task_without_claimed_at_uses_heartbeat_only():
    # No claimed_at (task predates lease tracking): grace cannot apply, fall back
    # to heartbeat staleness of the assignee.
    live = _task(assignee="silvio", claimed_secs_ago=None)
    assert is_orphaned(live, _agents(silvio=10), NOW, STALE, GRACE) is False
    dead = _task(assignee="silvio", claimed_secs_ago=None)
    assert is_orphaned(dead, _agents(silvio=999), NOW, STALE, GRACE) is True
