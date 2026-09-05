import json
import threading
import time
import urllib.request

from config import HTTP_TIMEOUT, LOG, RETENTION_DAYS
from db import DB, DB_IS_POSTGRES, DB_LOCK, db_execute, db_fetchone
from inventory import load_inventory


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
    with DB_LOCK:
        if DB_IS_POSTGRES:
            db_execute(
                 """
                insert into health(node, ok, latency_ms, error, ts)
                values(?, ?, ?, ?, ?)
                on conflict (node) do update set
                    ok = excluded.ok,
                    latency_ms = excluded.latency_ms,
                    error = excluded.error,
                    ts = excluded.ts
                 """,
                 (node, int(ok), latency_ms, error or "", int(time.time())),
             )
        else:
            db_execute(
                 "insert or replace into health(node, ok, latency_ms, error, ts) values(?, ?, ?, ?, ?)",
                 (node, int(ok), latency_ms, error or "", int(time.time())),
             )
        DB.commit()


def accumulate(node, stats, online):
    ts = int(time.time())
    with DB_LOCK:
        if not stats:
            db_execute(
                 "update totals set online = 0, active = 0, last_online = case when active = 1 then ? else last_online end where node = ?",
                 (ts, node),
             )
            DB.commit()
            return

        for user, traffic in stats.items():
            row = db_fetchone(
                 'select uplink, downlink, was_active from prev where node = ? and "user" = ?',
                 (node, user),
             )
            cur_up = int(traffic.get("uplink", 0))
            cur_down = int(traffic.get("downlink", 0))
            if row is None:
                delta_up = 0
                delta_down = 0
                was_active = False
            else:
                delta_up = max(0, cur_up - int(row["uplink"]))
                delta_down = max(0, cur_down - int(row["downlink"]))
                was_active = bool(row["was_active"])

            is_online = user in online
            is_active = delta_up > 0 or delta_down > 0

            if DB_IS_POSTGRES:
                db_execute(
                     'insert into totals(node, "user") values(?, ?) on conflict (node, "user") do nothing',
                     (node, user),
                )
            else:
                db_execute(
                     'insert or ignore into totals(node, "user") values(?, ?)',
                     (node, user),
                )
            if is_active:
                db_execute(
                     'update totals set uplink = uplink + ?, downlink = downlink + ?, last_seen = ? where node = ? and "user" = ?',
                     (delta_up, delta_down, ts, node, user),
                )
                db_execute(
                     'insert into samples(node, "user", ts, uplink, downlink) values(?, ?, ?, ?, ?)',
                     (node, user, ts, delta_up, delta_down),
                )
            if was_active and not is_active:
                db_execute(
                     'update totals set last_online = ? where node = ? and "user" = ?',
                     (ts, node, user),
                )
            db_execute(
                 'update totals set online = ?, active = ? where node = ? and "user" = ?',
                 (int(is_online), int(is_active), node, user),
             )
            if DB_IS_POSTGRES:
                db_execute(
                     """
                    insert into prev(node, "user", uplink, downlink, was_active)
                    values(?, ?, ?, ?, ?)
                    on conflict (node, "user") do update set
                        uplink = excluded.uplink,
                        downlink = excluded.downlink,
                        was_active = excluded.was_active
                     """,
                     (node, user, cur_up, cur_down, int(is_active)),
                )
            else:
                db_execute(
                     'insert or replace into prev(node, "user", uplink, downlink, was_active) values(?, ?, ?, ?, ?)',
                     (node, user, cur_up, cur_down, int(is_active)),
                )

        cutoff = ts - RETENTION_DAYS * 86400
        db_execute("delete from samples where ts < ?", (cutoff,))
        DB.commit()


def poll_node(node):
    start = time.monotonic()
    base = f"http://{node['host']}:{node['port']}"
    name = node.get("name", "?")
    try:
        raw = fetch_json(base + "/stats", node.get("token", ""))
        online_raw = fetch_json(base + "/online", node.get("token", ""))
        latency = int((time.monotonic() - start) * 1000)
        set_health(name, True, latency)
        accumulate(name, parse_stats(raw), parse_online(online_raw))
    except Exception as exc:     # network, JSON, or DB errors must not kill the poller
        latency = int((time.monotonic() - start) * 1000)
        LOG.warning("poll %s failed: %s", name, exc)
        try:
            set_health(name, False, latency, exc.__class__.__name__)
            accumulate(name, {}, set())
        except Exception as db_exc:     # last-ditch: a DB error must not crash the thread
            LOG.error("record poll failure for %s: %s", name, db_exc)


def poll_loop():
    while True:
        started = time.monotonic()
        try:
            nodes = load_inventory()
        except Exception as exc:     # transient inventory read/parse must not kill the poller
            LOG.warning("load_inventory failed: %s", exc)
            nodes = []
        threads = []
        for node in nodes:
            thread = threading.Thread(target=poll_node, args=(node,), daemon=True)
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join(timeout=HTTP_TIMEOUT + 1)
        elapsed = time.monotonic() - started
        time.sleep(max(1, POLL_INTERVAL - elapsed))
