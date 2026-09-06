import logging
import os
import threading

from waitress import serve

from config import BIND, PORT, POLL_INTERVAL
from db import DB_IS_POSTGRES, init_db
from httpserver import app
from poller import poll_loop


def main():
    logging.basicConfig(level=os.environ.get("STATS_LOG_LEVEL", "INFO").upper(),
                       format="%(asctime)s %(levelname)s %(message)s")
    if BIND not in ("127.0.0.1", "localhost", "::1") and not os.environ.get("STATS_API_TOKEN"):
        raise SystemExit("STATS_API_TOKEN is required when STATS_BIND is not loopback")
    init_db()
    logging.getLogger("xray-stats").info("starting backend=%s bind=%s port=%d poll=%ds",
                                        "postgres" if DB_IS_POSTGRES else "sqlite",
                                        BIND, PORT, POLL_INTERVAL)
    threading.Thread(target=poll_loop, daemon=True).start()
    serve(app, host=BIND, port=PORT, threads=8)


if __name__ == "__main__":
    main()
