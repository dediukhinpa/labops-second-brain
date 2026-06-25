"""Durable-task-queue supervisor: detect and requeue orphaned in-progress tasks.

When an agent claims a task (status -> progress) and then dies or hangs, the task
would otherwise sit in `progress` forever. The supervisor periodically finds such
orphaned tasks — claimer dead (stale heartbeat) or absent, past a grace window —
and transitions them progress -> new so another agent can pick them up.

`is_orphaned` is a pure predicate (no DB) so the reclaim decision is testable in
isolation and never accidentally evaluated against live data in a unit test.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

logger = logging.getLogger(__name__)

# Defaults (seconds). Heartbeat cadence in the swarm is well under STALE.
DEFAULT_STALE_AFTER_SECONDS = 180
DEFAULT_GRACE_SECONDS = 90
DEFAULT_INTERVAL_SECONDS = 60


def is_orphaned(
    task: dict[str, Any],
    agents: dict[str, datetime],
    now: datetime,
    stale_after_seconds: float,
    grace_seconds: float,
) -> bool:
    """Return True if an in-progress task should be requeued.

    Args:
        task: dict with ``status``, ``assignee`` (str|None), ``claimed_at``
            (datetime|None).
        agents: map of agent_name -> last_seen datetime (from the agents table).
        now: current time (tz-aware, same tz as the timestamps).
        stale_after_seconds: a heartbeat older than this means the agent is dead.
        grace_seconds: tasks claimed more recently than this are left alone, so a
            just-claimed task isn't yanked before its agent's first heartbeat.

    Rules: only ``progress`` tasks are eligible; within the grace window (by
    ``claimed_at``) never reclaim; otherwise orphaned iff the assignee is missing,
    unknown to the registry, or its last heartbeat is older than the stale window.
    """
    if task.get("status") != "progress":
        return False

    claimed_at = task.get("claimed_at")
    if claimed_at is not None and (now - claimed_at).total_seconds() < grace_seconds:
        return False

    assignee = task.get("assignee")
    if not assignee:
        return True

    last_seen = agents.get(assignee)
    if last_seen is None:
        return True

    return (now - last_seen).total_seconds() > stale_after_seconds
