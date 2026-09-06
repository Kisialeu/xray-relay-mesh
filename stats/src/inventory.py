import json
import os

from config import INVENTORY


def load_inventory():
    inv = load_raw_inventory()
    stats_cfg = inv.get("stats", {})
    master_node = stats_cfg.get("master_node", "")
    local_port = int(stats_cfg.get("node_port", 9091))
    ssh_user = os.environ.get("STATS_SSH_USER") or stats_cfg.get("ssh_user", "stats-poller")
    ssh_port = int(os.environ.get("STATS_SSH_PORT", stats_cfg.get("ssh_port", 22)))
    nodes = []
    for node in inv.get("nodes", []):
        is_self = node["name"] == master_node
        host = "127.0.0.1" if is_self else node.get("stats_host") or node.get("host")
        if not host:
            continue
        nodes.append({
             "name": node["name"],
             "friendly_name": node.get("friendly_name") or node["name"],
             "host": host,
             "port": local_port,
             "ssh_user": ssh_user,
             "ssh_port": ssh_port,
         })
    return nodes


def load_raw_inventory():
    with INVENTORY.open() as f:
        return json.load(f)


def node_names():
    return {node["name"] for node in load_raw_inventory().get("nodes", [])}


def master_node():
    return load_raw_inventory().get("stats", {}).get("master_node", "")
