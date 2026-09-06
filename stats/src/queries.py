import time

from sqlalchemy import select

from config import ACTIVE_DURATION, MIN_ACTIVITY_BYTES, ONLINE_WINDOW
from db import session_scope
from models import Health, Sample, Total


def _health_dict(item):
    return {
        "node": item.node,
        "ok": bool(item.ok),
        "latency_ms": item.latency_ms,
        "error": item.error or "",
        "ts": item.ts,
    }


def _total_dict(item):
    last_seen = item.last_seen
    now = int(time.time())
    recently_seen = last_seen is not None and int(last_seen) >= now - ONLINE_WINDOW
    continuously_active = (
        bool(item.active)
        and item.active_since is not None
        and int(item.active_since) <= now - ACTIVE_DURATION
        and int(item.active_bytes) >= MIN_ACTIVITY_BYTES
    )
    return {
        "node": item.node,
        "user": item.user_name,
        "uplink": item.uplink,
        "downlink": item.downlink,
        "total": item.uplink + item.downlink,
        "online": recently_seen and continuously_active,
        "active": bool(item.active),
        "last_seen": item.last_seen,
        "last_online": item.last_online,
    }


def health_rows():
    with session_scope() as session:
        items = session.scalars(select(Health).order_by(Health.node)).all()
        return [_health_dict(item) for item in items]


def node_user_rows(node):
    with session_scope() as session:
        items = session.scalars(
            select(Total).where(Total.node == node).order_by(Total.user_name)
        ).all()
        result = [_total_dict(item) for item in items]
        return sorted(result, key=lambda item: (-item["total"], item["user"]))


def user_rows():
    with session_scope() as session:
        items = session.scalars(
            select(Total).order_by(Total.node, Total.user_name)
        ).all()
        result = [_total_dict(item) for item in items]
        return sorted(result, key=lambda item: (-item["total"], item["node"], item["user"]))


def summary():
    return {"nodes": health_rows(), "users": user_rows()}


def user_history(node, user, limit=96):
    """Return recent per-poll traffic deltas for one node/user pair."""
    limit = max(1, min(int(limit), 500))
    with session_scope() as session:
        items = session.scalars(
            select(Sample)
            .where(Sample.node == node, Sample.user_name == user)
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()
        return [
            {"ts": item.ts, "uplink": item.uplink, "downlink": item.downlink, "total": item.uplink + item.downlink}
            for item in reversed(items)
        ]


def user_history_all(user, limit=500):
    """Return recent traffic deltas for a user across all nodes."""
    limit = max(1, min(int(limit), 500))
    with session_scope() as session:
        items = session.scalars(
            select(Sample)
            .where(Sample.user_name == user)
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()
        return [
            {
                "node": item.node,
                "ts": item.ts,
                "uplink": item.uplink,
                "downlink": item.downlink,
                "total": item.uplink + item.downlink,
            }
            for item in reversed(items)
        ]


def node_history(node, limit=500):
    """Return recent traffic totals per poll for one node."""
    limit = max(1, min(int(limit), 500))
    with session_scope() as session:
        items = session.scalars(
            select(Sample)
            .where(Sample.node == node)
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()

    grouped = {}
    for item in reversed(items):
        current = grouped.setdefault(item.ts, {"ts": item.ts, "uplink": 0, "downlink": 0, "total": 0})
        current["uplink"] += item.uplink
        current["downlink"] += item.downlink
        current["total"] += item.uplink + item.downlink
    return list(grouped.values())
