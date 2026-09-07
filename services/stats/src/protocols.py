# Per-protocol stats adapters. Each entry says how to ask a node for raw
# stats/online data (as an SSH forced-command name and a local HTTP path -
# see deploy/assets/stats.py and stats/deploy_stats.sh's wrapper, which must
# both expose the matching route/case for whatever is listed here), and how
# to parse that protocol's own response shape into the common form the rest
# of the pipeline (poller/models/queries) works with:
#   stats:  {user: {"uplink": int, "downlink": int}}
#   online: {user, ...} (a set)
#
# Adding a protocol means adding one entry below (plus the matching route in
# deploy/assets/stats.py's PROTOCOLS and the matching case in
# stats/deploy_stats.sh's SSH wrapper) - poller.py, models.py, and queries.py
# all key on "protocol" generically and need no further changes.


def _parse_xray_stats(raw):
    result = {}
    for item in raw.get("stat", []):
        name = item.get("name", "")
        parts = name.split(">>>")
        if len(parts) != 4 or parts[0] != "user" or parts[2] != "traffic":
            continue
        user = parts[1]
        direction = parts[3]
        if direction not in ("uplink", "downlink"):
            continue
        result.setdefault(user, {"uplink": 0, "downlink": 0})
        result[user][direction] = int(item.get("value") or 0)
    return result


def _parse_xray_online(raw):
    users = set()
    for entry in raw.get("users", []):
        if not isinstance(entry, str) or not entry:
            continue
        parts = entry.split(">>>")
        users.add(parts[1] if len(parts) >= 2 else entry)
    return users


def _parse_hysteria_stats(raw):
    # Hysteria2's /traffic returns {user: {"tx": int, "rx": int}} - tx/rx are
    # from the SERVER's point of view (tx = sent to the client = the user's
    # download; rx = received from the client = the user's upload), the
    # opposite orientation from Xray's user-centric uplink/downlink naming.
    result = {}
    for user, counters in raw.items():
        if not isinstance(counters, dict):
            continue
        result[user] = {
            "uplink": int(counters.get("rx") or 0),
            "downlink": int(counters.get("tx") or 0),
        }
    return result


def _parse_hysteria_online(raw):
    # Hysteria2's /online returns {user: <active connection count>}.
    return {user for user, count in raw.items() if int(count or 0) > 0}


PROTOCOLS = {
    "xray": {
        "ssh_stats": "xray:stats",
        "ssh_online": "xray:online",
        "local_stats": "/xray/stats",
        "local_online": "/xray/online",
        "parse_stats": _parse_xray_stats,
        "parse_online": _parse_xray_online,
    },
    "hysteria": {
        "ssh_stats": "hysteria:stats",
        "ssh_online": "hysteria:online",
        "local_stats": "/hysteria/stats",
        "local_online": "/hysteria/online",
        "parse_stats": _parse_hysteria_stats,
        "parse_online": _parse_hysteria_online,
    },
}
