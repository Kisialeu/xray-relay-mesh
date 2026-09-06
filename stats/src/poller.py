import json
import subprocess
import threading
import time
import urllib.request

from sqlalchemy import delete, select

from config import HTTP_TIMEOUT, LOG, POLL_INTERVAL, RETENTION_DAYS, SSH_KEY, SSH_KNOWN_HOSTS
from db import session_scope
from inventory import load_inventory
from models import Health, Previous, Sample, Total


def parse_stats(raw):
    result = {}
    for item in raw.get("stat", []):
        name = item.get("name", "")
        parts = name.split(">>>")
        if len(parts) != 4:
            continue
        user = parts[1]
        direction = parts[3]
        if direction not in ("uplink", "downlink"):
            continue
        result.setdefault(user, {"uplink": 0, "downlink": 0})
        result[user][direction] = int(item.get("value") or 0)
    return result


def parse_online(raw):
    users = set()
    for entry in raw.get("users", []):
        parts = entry.split(">>>")
        if len(parts) >= 2:
            users.add(parts[1])
    return users


def fetch_json(url, token=""):
    headers = {"Accept": "application/json"}
    if token:
        headers["X-Stats-Token"] = token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def set_health(node, ok, latency_ms, error=None):
    with session_scope() as session:
        health = session.get(Health, node)
        if health is None:
            health = Health(node=node, ok=bool(ok), latency_ms=latency_ms, error=error or "", ts=int(time.time()))
            session.add(health)
        else:
            health.ok = bool(ok)
            health.latency_ms = latency_ms
            health.error = error or ""
            health.ts = int(time.time())


def accumulate(node, stats, online):
    ts = int(time.time())
    with session_scope() as session:
        if not stats:
            totals = session.scalars(select(Total).where(Total.node == node)).all()
            for total in totals:
                if total.active:
                    total.last_online = ts
                total.online = False
                total.active = False
                total.active_since = None
                total.active_bytes = 0
            return

        for user, traffic in stats.items():
            previous = session.get(Previous, (node, user))
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

            total = session.get(Total, (node, user))
            if total is None:
                total = Total(node=node, user_name=user, uplink=0, downlink=0)
                session.add(total)
            if is_active:
                if not was_active:
                    total.active_since = ts
                    total.active_bytes = 0
                total.active_bytes += activity_bytes
                total.uplink += delta_up
                total.downlink += delta_down
                total.last_seen = ts
                session.add(Sample(node=node, user_name=user, ts=ts, uplink=delta_up, downlink=delta_down))
            else:
                total.active_since = None
                total.active_bytes = 0
            if was_active and not is_active:
                total.last_online = ts
            total.online = is_online
            total.active = is_active

            if previous is None:
                session.add(Previous(node=node, user_name=user, uplink=cur_up, downlink=cur_down, was_active=is_active))
            else:
                previous.uplink = cur_up
                previous.downlink = cur_down
                previous.was_active = is_active

        cutoff = ts - RETENTION_DAYS * 86400
        session.execute(delete(Sample).where(Sample.ts < cutoff))


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


def poll_node(node):
    start = time.monotonic()
    name = node.get("name", "?")
    try:
        if node.get("host") == "127.0.0.1":
            base = f"http://127.0.0.1:{node['port']}"
            raw = fetch_json(base + "/stats")
            online_raw = fetch_json(base + "/online")
        else:
            raw = fetch_ssh(node, "stats")
            online_raw = fetch_ssh(node, "online")
        latency = int((time.monotonic() - start) * 1000)
        set_health(name, True, latency)
        accumulate(name, parse_stats(raw), parse_online(online_raw))
    except Exception as exc:      # network, JSON, or DB errors must not kill the poller
        latency = int((time.monotonic() - start) * 1000)
        LOG.warning("poll %s failed: %s", name, exc)
        try:
            set_health(name, False, latency, exc.__class__.__name__)
            accumulate(name, {}, set())
        except Exception as db_exc:      # last-ditch: a DB error must not crash the thread
            LOG.error("record poll failure for %s: %s", name, db_exc)


def poll_loop():
    while True:
        started = time.monotonic()
        try:
            nodes = load_inventory()
        except Exception as exc:      # transient inventory read/parse must not kill the poller
            LOG.warning("load_inventory failed: %s", exc)
            nodes = []
        threads = []
        for node in nodes:
            thread = threading.Thread(target=poll_node, args=(node,), daemon=True)
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join(timeout=2 * (HTTP_TIMEOUT + 2) + 1)
        elapsed = time.monotonic() - started
        time.sleep(max(1, POLL_INTERVAL - elapsed))
