import json
import os

from config import INVENTORY


def load_inventory():
    with INVENTORY.open() as f:
        inv = json.load(f)
    stats_cfg = inv.get("stats", {})
    master_node = stats_cfg.get("master_node", "")
    local_port = int(stats_cfg.get("node_port", 9091))
    public_port = int(stats_cfg.get("public_port") or local_port)
    node_token = os.environ.get("STATS_NODE_TOKEN") or stats_cfg.get("token", "")
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
             "port": local_port if is_self else int(node.get("stats_port") or public_port),
             "token": "" if is_self else node.get("stats_token") or node_token,
         })
    return nodes
