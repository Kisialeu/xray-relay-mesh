import logging
import os
from pathlib import Path

INVENTORY = Path(os.environ.get("INVENTORY", "inventory.json"))
DB_PATH = Path(os.environ.get("STATS_DB", "stats/stats.sqlite3"))
DATABASE_URL = os.environ.get("STATS_DATABASE_URL", "")
POLL_INTERVAL = int(os.environ.get("STATS_POLL_INTERVAL", "15"))
BIND = os.environ.get("STATS_BIND", "127.0.0.1")
PORT = int(os.environ.get("STATS_APP_PORT", os.environ.get("STATS_WEB_PORT", "8088")))
API_TOKEN = os.environ.get("STATS_API_TOKEN", "")
HTTP_TIMEOUT = float(os.environ.get("STATS_HTTP_TIMEOUT", "5"))
RETENTION_DAYS = int(os.environ.get("STATS_RETENTION_DAYS", "60"))
ONLINE_WINDOW = int(os.environ.get("STATS_ONLINE_WINDOW", "300"))
ACTIVE_DURATION = int(os.environ.get("STATS_ACTIVE_DURATION", "60"))
MIN_ACTIVITY_BYTES = int(os.environ.get("STATS_MIN_ACTIVITY_BYTES", "1024"))
SSH_KEY = os.environ.get("STATS_SSH_KEY", "/app/ssh/id_ed25519")
SSH_KNOWN_HOSTS = os.environ.get("STATS_SSH_KNOWN_HOSTS", "/app/ssh/known_hosts")
SSH_USER = os.environ.get("STATS_SSH_USER", "stats-poller")
SSH_PORT = int(os.environ.get("STATS_SSH_PORT", "22"))

LOG = logging.getLogger("xray-stats")
