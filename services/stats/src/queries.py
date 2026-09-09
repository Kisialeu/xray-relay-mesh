import time

from sqlalchemy import case, func, select

from config import ACTIVE_DURATION, HTTP_TIMEOUT, MIN_ACTIVITY_BYTES, ONLINE_WINDOW, POLL_INTERVAL
from db import session_scope
from inventory import node_names, node_protocol_pairs
from models import Health, PollRun, Sample, Total


HEALTH_STALE_AFTER = max(POLL_INTERVAL * 3, int(POLL_INTERVAL + HTTP_TIMEOUT * 3))


def _health_status(item, now=None):
    now = int(time.time()) if now is None else now
    stale = int(item.ts) < now - HEALTH_STALE_AFTER
    ok = bool(item.ok) and not stale
    error = item.error or ""
    if stale and not error:
        error = "stale poll data"
    return ok, error


def _health_dict(item):
    ok, error = _health_status(item)
    return {
        "node": item.node,
        "protocol": item.protocol,
        "ok": ok,
        "latency_ms": item.latency_ms,
        "error": error,
        "ts": item.ts,
    }


def _total_dict(item, available=True):
    last_seen = item.last_seen
    now = int(time.time())
    recently_seen = last_seen is not None and int(last_seen) >= now - ONLINE_WINDOW
    continuously_active = (
        available
        and bool(item.active)
        and item.active_since is not None
        and int(item.active_since) <= now - ACTIVE_DURATION
        and int(item.active_bytes) >= MIN_ACTIVITY_BYTES
    )
    online = bool(item.online) and recently_seen and continuously_active
    if not available:
        presence = "unknown"
    elif online:
        presence = "online"
    elif item.active:
        presence = "active"
    else:
        presence = "offline"
    return {
        "node": item.node,
        "protocol": item.protocol,
        "user": item.user_name,
        "uplink": item.uplink,
        "downlink": item.downlink,
        "total": item.uplink + item.downlink,
        "online": online,
        "reported_online": bool(item.online),
        "available": available,
        "active": available and bool(item.active),
        "presence": presence,
        "last_seen": item.last_seen,
        "last_online": item.last_online,
    }


def health_rows():
    """One row per declared (node, protocol) pair - e.g. a node running both
    xray and hysteria can be healthy on one and failing on the other."""
    allowed = node_protocol_pairs()
    with session_scope() as session:
        items = session.scalars(select(Health)).all()
        by_pair = {(item.node, item.protocol): _health_dict(item) for item in items}
        return [
            by_pair.get((node, protocol), {
                "node": node,
                "protocol": protocol,
                "ok": False,
                "latency_ms": 0,
                "error": "no poll data",
                "ts": 0,
            })
            for node, protocol in sorted(allowed)
        ]


def _availability_by_node(nodes):
    """node -> {protocol: is_available_bool}, for the given node names."""
    with session_scope() as session:
        items = session.scalars(select(Health).where(Health.node.in_(nodes))).all()
    result = {}
    for item in items:
        result.setdefault(item.node, {})[item.protocol] = _health_status(item)[0]
    return result


def node_user_rows(node, period_seconds=None):
    """One row per (protocol, user) tracked on this node."""
    if node not in node_names():
        return []
    period_start = int(time.time()) - int(period_seconds) if period_seconds else None
    availability = _availability_by_node([node]).get(node, {})
    with session_scope() as session:
        items = session.scalars(
            select(Total).where(Total.node == node).order_by(Total.protocol, Total.user_name)
        ).all()
        result = [_total_dict(item, availability.get(item.protocol, False)) for item in items]
        if period_start is not None:
            period_rows = session.execute(
                select(
                    Sample.protocol,
                    Sample.user_name,
                    func.sum(Sample.uplink).label("uplink"),
                    func.sum(Sample.downlink).label("downlink"),
                )
                .where(Sample.node == node, Sample.ts >= period_start)
                .group_by(Sample.protocol, Sample.user_name)
            ).all()
            period = {
                (item.protocol, item.user_name): (int(item.uplink or 0), int(item.downlink or 0))
                for item in period_rows
            }
            for item in result:
                period_up, period_down = period.get((item["protocol"], item["user"]), (0, 0))
                item["period_uplink"] = period_up
                item["period_downlink"] = period_down
                item["period_total"] = period_up + period_down
        return sorted(result, key=lambda item: (-item["total"], item["user"], item["protocol"]))


def user_rows(period_seconds=None):
    """One row per (node, protocol, user) tracked anywhere in the mesh."""
    allowed = node_names()
    period_start = int(time.time()) - int(period_seconds) if period_seconds else None
    availability = _availability_by_node(allowed)
    with session_scope() as session:
        items = session.scalars(
            select(Total).where(Total.node.in_(allowed)).order_by(Total.node, Total.protocol, Total.user_name)
        ).all()
        result = [_total_dict(item, availability.get(item.node, {}).get(item.protocol, False)) for item in items]
        if period_start is not None:
            period_rows = session.execute(
                select(
                    Sample.node,
                    Sample.protocol,
                    Sample.user_name,
                    func.sum(Sample.uplink).label("uplink"),
                    func.sum(Sample.downlink).label("downlink"),
                )
                .where(Sample.node.in_(allowed), Sample.ts >= period_start)
                .group_by(Sample.node, Sample.protocol, Sample.user_name)
            ).all()
            period = {
                (item.node, item.protocol, item.user_name): (int(item.uplink or 0), int(item.downlink or 0))
                for item in period_rows
            }
            for item in result:
                period_up, period_down = period.get((item["node"], item["protocol"], item["user"]), (0, 0))
                item["period_uplink"] = period_up
                item["period_downlink"] = period_down
                item["period_total"] = period_up + period_down
        return sorted(result, key=lambda item: (-item["total"], item["node"], item["protocol"], item["user"]))


def summary(period_seconds=None):
    return {"nodes": health_rows(), "users": user_rows(period_seconds)}


def traffic_history(seconds=86400, bucket=300, node=None, user=None, protocol=None):
    """Return bucketed mesh traffic with successful-poll coverage. Coverage
    is measured per (node, protocol) pair - the unit of one independently
    pollable stats source - not per node, so a node with a partially-down
    protocol shows partial coverage instead of looking fully covered."""
    now = int(time.time())
    start = now - int(seconds)
    bucket = int(bucket)
    first_bucket = start - (start % bucket)
    last_bucket = now - (now % bucket)
    allowed = node_names()
    if node is not None:
        allowed = {node} if node in allowed else set()
    if not allowed:
        return {"bucket_seconds": bucket, "node_count": 0, "series": []}

    sample_bucket = Sample.ts - (Sample.ts % bucket)
    poll_bucket = PollRun.ts - (PollRun.ts % bucket)
    sample_filters = [Sample.node.in_(allowed), Sample.ts >= start]
    poll_filters = [PollRun.node.in_(allowed), PollRun.ts >= start, PollRun.ok.is_(True)]
    first_poll_filters = [PollRun.node.in_(allowed)]
    if user is not None:
        sample_filters.append(Sample.user_name == user)
    if protocol is not None:
        sample_filters.append(Sample.protocol == protocol)
        poll_filters.append(PollRun.protocol == protocol)
        first_poll_filters.append(PollRun.protocol == protocol)
    with session_scope() as session:
        traffic_rows = session.execute(
            select(
                sample_bucket.label("bucket"),
                func.sum(Sample.uplink).label("uplink"),
                func.sum(Sample.downlink).label("downlink"),
            )
            .where(*sample_filters)
            .group_by(sample_bucket)
        ).all()
        successful_poll_rows = session.execute(
            select(poll_bucket.label("bucket"), PollRun.node, PollRun.protocol)
            .where(*poll_filters)
            .group_by(poll_bucket, PollRun.node, PollRun.protocol)
        ).all()
        first_poll_rows = session.execute(
            select(PollRun.node, PollRun.protocol, func.min(PollRun.ts).label("ts"))
            .where(*first_poll_filters)
            .group_by(PollRun.node, PollRun.protocol)
        ).all()

    traffic = {
        int(item.bucket): (int(item.uplink or 0), int(item.downlink or 0))
        for item in traffic_rows
    }
    successful = {}
    for item in successful_poll_rows:
        successful.setdefault(int(item.bucket), set()).add((item.node, item.protocol))
    first_polls = {
        (item.node, item.protocol): int(item.ts) - (int(item.ts) % bucket)
        for item in first_poll_rows
    }

    series = []
    for timestamp in range(first_bucket, last_bucket + 1, bucket):
        values = traffic.get(timestamp)
        expected_sources = sum(first_bucket_ts <= timestamp for first_bucket_ts in first_polls.values())
        is_legacy = expected_sources == 0
        successful_sources = len(successful.get(timestamp, set()))
        if is_legacy:
            coverage = None
            available = values is not None
        else:
            coverage = successful_sources / expected_sources
            available = successful_sources > 0
        uplink, downlink = values if values is not None else (0, 0)
        series.append({
            "ts": timestamp,
            "uplink": uplink if available else None,
            "downlink": downlink if available else None,
            "total": uplink + downlink if available else None,
            "coverage": coverage,
        })
    return {"bucket_seconds": bucket, "node_count": len(allowed), "series": series}


def node_analytics(node, seconds=86400, bucket=300):
    if node not in node_names():
        return None
    now = int(time.time())
    start = now - int(seconds)
    with session_scope() as session:
        poll = session.execute(
            select(
                func.count(PollRun.id).label("total"),
                func.sum(case((PollRun.ok.is_(True), 1), else_=0)).label("successful"),
                func.avg(PollRun.latency_ms).label("latency"),
            ).where(PollRun.node == node, PollRun.ts >= start)
        ).one()
        active_users = session.scalar(
            select(func.count(func.distinct(Sample.user_name))).where(
                Sample.node == node,
                Sample.ts >= start,
            )
        ) or 0
    total_polls = int(poll.total or 0)
    successful_polls = int(poll.successful or 0)
    return {
        "seconds": int(seconds),
        "active_users": int(active_users),
        "polls": total_polls,
        "successful_polls": successful_polls,
        "availability": successful_polls / total_polls if total_polls else None,
        "average_latency_ms": round(float(poll.latency), 1) if poll.latency is not None else None,
        "traffic": traffic_history(seconds, bucket, node=node),
    }


def user_analytics(user, seconds=86400, bucket=300):
    allowed = node_names()
    now = int(time.time())
    start = now - int(seconds)
    with session_scope() as session:
        tracked = session.scalar(
            select(func.count()).select_from(Total).where(
                Total.node.in_(allowed),
                Total.user_name == user,
            )
        )
        if not tracked:
            return None
        active_nodes = session.scalar(
            select(func.count(func.distinct(Sample.node))).where(
                Sample.node.in_(allowed),
                Sample.user_name == user,
                Sample.ts >= start,
            )
        ) or 0
    return {
        "seconds": int(seconds),
        "active_nodes": int(active_nodes),
        "traffic": traffic_history(seconds, bucket, user=user),
    }


def user_history(node, user, limit=96):
    """Return recent per-poll traffic deltas for one node/user, across
    whichever protocols that user has traffic on for this node."""
    limit = max(1, min(int(limit), 500))
    with session_scope() as session:
        items = session.scalars(
            select(Sample)
            .where(Sample.node == node, Sample.user_name == user)
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()
        return [
            {
                "ts": item.ts,
                "protocol": item.protocol,
                "uplink": item.uplink,
                "downlink": item.downlink,
                "total": item.uplink + item.downlink,
            }
            for item in reversed(items)
        ]


def user_history_all(user, limit=500):
    """Return recent traffic deltas for a user across all nodes/protocols."""
    limit = max(1, min(int(limit), 500))
    with session_scope() as session:
        items = session.scalars(
            select(Sample)
            .where(Sample.user_name == user, Sample.node.in_(node_names()))
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()
        return [
            {
                "node": item.node,
                "protocol": item.protocol,
                "ts": item.ts,
                "uplink": item.uplink,
                "downlink": item.downlink,
                "total": item.uplink + item.downlink,
            }
            for item in reversed(items)
        ]


def node_history(node, limit=500):
    """Return recent traffic totals per poll for one node, summed across
    every protocol running on it."""
    limit = max(1, min(int(limit), 500))
    if node not in node_names():
        return []
    with session_scope() as session:
        items = session.execute(
            select(
                Sample.ts,
                func.sum(Sample.uplink).label("uplink"),
                func.sum(Sample.downlink).label("downlink"),
            )
            .where(Sample.node == node)
            .group_by(Sample.ts)
            .order_by(Sample.ts.desc())
            .limit(limit)
        ).all()
    return [
        {"ts": item.ts, "uplink": item.uplink, "downlink": item.downlink, "total": item.uplink + item.downlink}
        for item in reversed(items)
    ]
