import logging
import os
from pathlib import Path

INVENTORY = Path(os.environ.get("INVENTORY", "inventory.json"))
DB_PATH = Path(os.environ.get("STATS_DB", "stats/stats.sqlite3"))
DATABASE_URL = os.environ.get("STATS_DATABASE_URL", "")
POLL_INTERVAL = int(os.environ.get("STATS_POLL_INTERVAL", "15"))
BIND = os.environ.get("STATS_BIND", "127.0.0.1")
PORT = int(os.environ.get("STATS_WEB_PORT", "8088"))
API_TOKEN = os.environ.get("STATS_API_TOKEN", "")
NODE_TOKEN = os.environ.get("STATS_NODE_TOKEN", "")
HTTP_TIMEOUT = float(os.environ.get("STATS_HTTP_TIMEOUT", "5"))
RETENTION_DAYS = int(os.environ.get("STATS_RETENTION_DAYS", "30"))

LOG = logging.getLogger("xray-stats")
