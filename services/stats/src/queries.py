import time

from sqlalchemy import case, func, select

from config import ACTIVE_DURATION, HTTP_TIMEOUT, MIN_ACTIVITY_BYTES, ONLINE_WINDOW, POLL_INTERVAL, RETENTION_DAYS
from db import session_scope
from inventory import node_names, node_protocol_pairs
from models import Event, Health, PollRun, Sample, Total


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


def poll_history(seconds=86400, bucket=1800):
    """Bucketed poll results per node (all protocols together). A bucket
    without polls is None so charts can show missing collector data."""
    now = int(time.time())
    start = now - int(seconds)
    bucket = int(bucket)
    first_bucket = start - (start % bucket)
    last_bucket = now - (now % bucket)
    allowed = node_names()
    poll_bucket = PollRun.ts - (PollRun.ts % bucket)
    with session_scope() as session:
        rows = session.execute(
            select(
                PollRun.node,
                poll_bucket.label("bucket"),
                func.count(PollRun.id).label("polls"),
                func.sum(case((PollRun.ok.is_(True), 0), else_=1)).label("failed"),
                func.avg(case((PollRun.ok.is_(True), PollRun.latency_ms))).label("latency"),
                func.max(case((PollRun.ok.is_(True), PollRun.latency_ms))).label("max_latency"),
            )
            .where(PollRun.node.in_(allowed), PollRun.ts >= start)
            .group_by(PollRun.node, poll_bucket)
        ).all()
    by_node = {name: {} for name in sorted(allowed)}
    for row in rows:
        by_node[row.node][int(row.bucket)] = {
            "polls": int(row.polls),
            "failed": int(row.failed or 0),
            "average_latency_ms": round(float(row.latency), 1) if row.latency is not None else None,
            "max_latency_ms": int(row.max_latency) if row.max_latency is not None else None,
        }
    empty = {"polls": 0, "failed": 0, "average_latency_ms": None, "max_latency_ms": None}
    return {
        "bucket_seconds": bucket,
        "nodes": {
            name: [{"ts": ts, **buckets.get(ts, empty)} for ts in range(first_bucket, last_bucket + 1, bucket)]
            for name, buckets in by_node.items()
        },
    }


def user_sessions(user, seconds=86400, limit=20):
    """Sessions derived from traffic samples: consecutive active polls form one
    session, a gap longer than ONLINE_WINDOW starts a new one."""
    allowed = node_names()
    start = int(time.time()) - int(seconds)
    with session_scope() as session:
        tracked = session.scalar(
            select(func.count()).select_from(Total).where(Total.node.in_(allowed), Total.user_name == user)
        )
        if not tracked:
            return None
        first_seen = session.scalar(
            select(func.min(Sample.ts)).where(Sample.node.in_(allowed), Sample.user_name == user)
        )
        rows = session.execute(
            select(Sample.ts, func.sum(Sample.uplink + Sample.downlink).label("bytes"))
            .where(Sample.node.in_(allowed), Sample.user_name == user, Sample.ts >= start)
            .group_by(Sample.ts)
            .order_by(Sample.ts)
        ).all()
    sessions = []
    for row in rows:
        if sessions and row.ts - sessions[-1]["end"] <= ONLINE_WINDOW:
            sessions[-1]["end"] = int(row.ts)
            sessions[-1]["bytes"] += int(row.bytes or 0)
        else:
            sessions.append({"start": int(row.ts), "end": int(row.ts), "bytes": int(row.bytes or 0)})
    for item in sessions:
        item["duration_seconds"] = item["end"] - item["start"] + POLL_INTERVAL
    durations = sorted(item["duration_seconds"] for item in sessions)
    return {
        "seconds": int(seconds),
        "first_seen": first_seen,
        "count": len(sessions),
        "median_seconds": durations[len(durations) // 2] if durations else None,
        "longest_seconds": durations[-1] if durations else None,
        "total_seconds": sum(durations),
        "sessions": sessions[::-1][:max(1, min(int(limit), 100))],
    }


def event_rows(limit=50, node=None, user=None):
    limit = max(1, min(int(limit), 200))
    query = select(Event).where(Event.node.in_(node_names()))
    if node is not None:
        query = query.where(Event.node == node)
    if user is not None:
        query = query.where(Event.user_name == user)
    with session_scope() as session:
        items = session.scalars(query.order_by(Event.ts.desc(), Event.id.desc()).limit(limit)).all()
        return [
            {"ts": item.ts, "kind": item.kind, "node": item.node, "protocol": item.protocol, "user": item.user_name, "text": item.text}
            for item in items
        ]


def dashboard(seconds, bucket, traffic_seconds, poll_bucket):
    """Everything the dashboard page needs in one response, so one refresh is
    one request (the proxy rate-limits /api/)."""
    data = summary(seconds)
    return {
        "nodes": data["nodes"],
        "users": data["users"],
        "traffic": traffic_history(traffic_seconds, bucket),
        "polls": poll_history(seconds, poll_bucket),
        "events": event_rows(30),
        "analytics": {name: node_analytics(name, seconds, bucket) for name in sorted(node_names())},
    }


def analytics(seconds=86400, bucket=900):
    """Longer-term usage figures that the live dashboard does not need on every
    refresh: previous-period totals, active users, DAU/WAU/MAU, and hourly
    traffic for the weekday/hour heatmap."""
    now = int(time.time())
    allowed = node_names()
    retention = RETENTION_DAYS * 86400
    traffic_bytes = func.sum(Sample.uplink + Sample.downlink)
    bucket_ts = Sample.ts - (Sample.ts % bucket)
    day_ts = Sample.ts - (Sample.ts % 86400)
    in_nodes = Sample.node.in_(allowed)

    def distinct_users(days):
        return session.scalar(
            select(func.count(func.distinct(Sample.user_name))).where(in_nodes, Sample.ts >= now - days * 86400)
        ) or 0

    with session_scope() as session:
        previous = None
        if seconds * 2 <= retention:
            previous = {}
            window = (in_nodes, Sample.ts >= now - 2 * seconds, Sample.ts < now - seconds)
            for key, column in (("users", Sample.user_name), ("nodes", Sample.node)):
                rows = session.execute(select(column, traffic_bytes).where(*window).group_by(column)).all()
                previous[key] = {name: int(total or 0) for name, total in rows}
        active = session.execute(
            select(bucket_ts, func.count(func.distinct(Sample.user_name)))
            .where(in_nodes, Sample.ts >= now - seconds)
            .group_by(bucket_ts)
        ).all()
        daily = session.execute(
            select(day_ts, func.count(func.distinct(Sample.user_name)))
            .where(in_nodes, Sample.ts >= now - min(30 * 86400, retention))
            .group_by(day_ts)
        ).all()
        first_seen = session.execute(
            select(func.min(Sample.ts)).where(in_nodes).group_by(Sample.user_name)
        ).scalars().all()
        activity = {"dau": distinct_users(1), "wau": distinct_users(7), "mau": distinct_users(30)}
    activity["new_7d"] = sum(1 for ts in first_seen if ts >= now - 7 * 86400)
    activity["new_30d"] = sum(1 for ts in first_seen if ts >= now - 30 * 86400)
    activity["daily"] = [{"ts": int(ts), "users": int(count)} for ts, count in sorted(daily)]
    return {
        "seconds": int(seconds),
        "bucket_seconds": int(bucket),
        "previous": previous,
        "active_users": [{"ts": int(ts), "users": int(count)} for ts, count in sorted(active)],
        "activity": activity,
        "hourly": traffic_history(min(28 * 86400, retention), 3600),
    }
