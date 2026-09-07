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
RETENTION_DAYS = int(os.environ.get("STATS_RETENTION_DAYS", "90"))
ONLINE_WINDOW = int(os.environ.get("STATS_ONLINE_WINDOW", "120"))
ACTIVE_DURATION = int(os.environ.get("STATS_ACTIVE_DURATION", "30"))
MIN_ACTIVITY_BYTES = int(os.environ.get("STATS_MIN_ACTIVITY_BYTES", "1024"))
SSH_KEY = os.environ.get("STATS_SSH_KEY", "/app/ssh/id_ed25519")
SSH_KNOWN_HOSTS = os.environ.get("STATS_SSH_KNOWN_HOSTS", "/app/ssh/known_hosts")
SSH_USER = os.environ.get("STATS_SSH_USER", "stats-poller")
SSH_PORT = int(os.environ.get("STATS_SSH_PORT", "22"))


def validate_config():
    positive = {
        "STATS_POLL_INTERVAL": POLL_INTERVAL,
        "STATS_HTTP_TIMEOUT": HTTP_TIMEOUT,
        "STATS_RETENTION_DAYS": RETENTION_DAYS,
        "STATS_ONLINE_WINDOW": ONLINE_WINDOW,
        "STATS_ACTIVE_DURATION": ACTIVE_DURATION,
        "STATS_MIN_ACTIVITY_BYTES": MIN_ACTIVITY_BYTES,
    }
    invalid = [name for name, value in positive.items() if value <= 0]
    if invalid:
        raise ValueError(f"configuration values must be positive: {', '.join(invalid)}")
    if RETENTION_DAYS > 90:
        raise ValueError("STATS_RETENTION_DAYS must not exceed 90")
    if not 1 <= PORT <= 65535:
        raise ValueError("STATS_APP_PORT must be in range 1-65535")
    if not 1 <= SSH_PORT <= 65535:
        raise ValueError("STATS_SSH_PORT must be in range 1-65535")


LOG = logging.getLogger("xray-stats")
