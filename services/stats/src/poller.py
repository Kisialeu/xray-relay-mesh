import json
import subprocess
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from sqlalchemy import delete, select

from config import ACTIVE_DURATION, HTTP_TIMEOUT, LOG, MIN_ACTIVITY_BYTES, POLL_INTERVAL, RETENTION_DAYS, SSH_KEY, SSH_KNOWN_HOSTS
from db import session_scope
from inventory import load_inventory
from models import Health, PollRun, Previous, Sample, Total
from protocols import PROTOCOLS


POLL_STATE = {"last_started": 0.0, "last_completed": 0.0, "last_error": "", "node_count": 0}
POLL_STATE_LOCK = threading.Lock()


def poller_status():
    with POLL_STATE_LOCK:
        return dict(POLL_STATE)


def _update_poll_state(**values):
    with POLL_STATE_LOCK:
        POLL_STATE.update(values)


def fetch_json(url, token=""):
    headers = {"Accept": "application/json"}
    if token:
        headers["X-Stats-Token"] = token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def set_health(node, protocol, ok, latency_ms, error=None):
    ts = int(time.time())
    with session_scope() as session:
        health = session.get(Health, (node, protocol))
        if health is None:
            health = Health(node=node, protocol=protocol, ok=bool(ok), latency_ms=latency_ms, error=error or "", ts=ts)
            session.add(health)
        else:
            health.ok = bool(ok)
            health.latency_ms = latency_ms
            health.error = error or ""
            health.ts = ts
        session.add(PollRun(
            node=node,
            protocol=protocol,
            ok=bool(ok),
            latency_ms=latency_ms,
            error=error or "",
            ts=ts,
        ))


def accumulate(node, protocol, stats, online):
    ts = int(time.time())
    with session_scope() as session:
        for user, traffic in stats.items():
            previous = session.get(Previous, (node, protocol, user))
            cur_up = int(traffic.get("uplink", 0))
            cur_down = int(traffic.get("downlink", 0))
            if previous is None:
                delta_up = 0
                delta_down = 0
                was_active = False
            else:
                delta_up = max(0, cur_up - int(previous.uplink))
                delta_down = max(0, cur_down - int(previous.downlink))
                was_active = bool(previous.was_active)

            is_online = user in online
            is_active = delta_up > 0 or delta_down > 0
            activity_bytes = delta_up + delta_down

            total = session.get(Total, (node, protocol, user))
            if total is None:
                total = Total(node=node, protocol=protocol, user_name=user, uplink=0, downlink=0)
                session.add(total)
            if is_active:
                if not was_active:
                    total.active_since = ts
                    total.active_bytes = 0
                total.active_bytes += activity_bytes
                total.uplink += delta_up
                total.downlink += delta_down
                total.last_seen = ts
                session.add(Sample(node=node, protocol=protocol, user_name=user, ts=ts, uplink=delta_up, downlink=delta_down))
            else:
                total.active_since = None
                total.active_bytes = 0
            total.online = is_online
            total.active = is_active
            if (
                is_online
                and is_active
                and total.active_since is not None
                and total.active_since <= ts - ACTIVE_DURATION
                and total.active_bytes >= MIN_ACTIVITY_BYTES
            ):
                total.last_online = ts

            if previous is None:
                session.add(Previous(node=node, protocol=protocol, user_name=user, uplink=cur_up, downlink=cur_down, was_active=is_active))
            else:
                previous.uplink = cur_up
                previous.downlink = cur_down
                previous.was_active = is_active

        current_users = set(stats)
        totals = session.scalars(select(Total).where(Total.node == node, Total.protocol == protocol)).all()
        for total in totals:
            if total.user_name in current_users:
                continue
            total.online = False
            total.active = False
            total.active_since = None
            total.active_bytes = 0

        previous_rows = session.scalars(select(Previous).where(Previous.node == node, Previous.protocol == protocol)).all()
        for previous in previous_rows:
            if previous.user_name not in current_users:
                previous.was_active = False


def mark_unavailable(node, protocol):
    """Reset transient activity without treating a failed poll as traffic data."""
    with session_scope() as session:
        totals = session.scalars(select(Total).where(Total.node == node, Total.protocol == protocol)).all()
        for total in totals:
            total.online = False
            total.active = False
            total.active_since = None
            total.active_bytes = 0
        previous_rows = session.scalars(select(Previous).where(Previous.node == node, Previous.protocol == protocol)).all()
        for previous in previous_rows:
            previous.was_active = False


def prune_samples():
    cutoff = int(time.time()) - RETENTION_DAYS * 86400
    with session_scope() as session:
        session.execute(delete(Sample).where(Sample.ts < cutoff))
        session.execute(delete(PollRun).where(PollRun.ts < cutoff))


def fetch_ssh(node, endpoint):
    command = [
        "ssh", "-i", SSH_KEY,
        "-p", str(node.get("ssh_port", 22)),
        "-o", "BatchMode=yes",
        "-o", f"ConnectTimeout={max(1, int(HTTP_TIMEOUT))}",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={SSH_KNOWN_HOSTS}",
        f"{node['ssh_user']}@{node['host']}", endpoint,
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=HTTP_TIMEOUT + 2,
            check=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"ssh {node['host']} {endpoint}: timeout") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip().splitlines()
        reason = detail[-1] if detail else f"exit status {exc.returncode}"
        raise RuntimeError(f"ssh {node['host']} {endpoint}: {reason}") from exc
    return json.loads(result.stdout)


def poll_node_protocol(node, protocol):
    adapter = PROTOCOLS.get(protocol)
    name = node.get("name", "?")
    if adapter is None:
        LOG.warning("poll %s: unknown protocol %r, skipping", name, protocol)
        return
    start = time.monotonic()
    try:
        if node.get("host") == "127.0.0.1":
            base = f"http://127.0.0.1:{node['port']}"
            raw = fetch_json(base + adapter["local_stats"])
            online_raw = fetch_json(base + adapter["local_online"])
        else:
            raw = fetch_ssh(node, adapter["ssh_stats"])
            online_raw = fetch_ssh(node, adapter["ssh_online"])
        latency = int((time.monotonic() - start) * 1000)
        accumulate(name, protocol, adapter["parse_stats"](raw), adapter["parse_online"](online_raw))
        set_health(name, protocol, True, latency)
    except Exception as exc:      # network, JSON, or DB errors must not kill the poller
        latency = int((time.monotonic() - start) * 1000)
        LOG.warning("poll %s/%s failed: %s", name, protocol, exc)
        try:
            set_health(name, protocol, False, latency, exc.__class__.__name__)
            mark_unavailable(name, protocol)
        except Exception as db_exc:      # last-ditch: a DB error must not crash the thread
            LOG.error("record poll failure for %s/%s: %s", name, protocol, db_exc)


def poll_node(node):
    for protocol in node.get("protocols") or ["xray"]:
        poll_node_protocol(node, protocol)


def poll_loop():
    next_cleanup = 0.0
    while True:
        started = time.monotonic()
        _update_poll_state(last_started=time.time())
        try:
            nodes = load_inventory()
        except Exception as exc:      # transient inventory read/parse must not kill the poller
            LOG.warning("load_inventory failed: %s", exc)
            nodes = []
            _update_poll_state(last_error=exc.__class__.__name__, node_count=0)
        else:
            _update_poll_state(last_error="", node_count=len(nodes))
        if nodes:
            with ThreadPoolExecutor(max_workers=min(len(nodes), 32), thread_name_prefix="stats-poll") as executor:
                list(executor.map(poll_node, nodes))
        _update_poll_state(last_completed=time.time())
        now = time.monotonic()
        if now >= next_cleanup:
            try:
                prune_samples()
            except Exception as exc:
                LOG.error("sample retention failed: %s", exc)
            next_cleanup = now + 3600
        elapsed = time.monotonic() - started
        time.sleep(max(1, POLL_INTERVAL - elapsed))
