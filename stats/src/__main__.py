import logging
import os
import threading
from http.server import ThreadingHTTPServer

from config import BIND, PORT, POLL_INTERVAL
from db import DB_IS_POSTGRES, init_db
from httpserver import Handler
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
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
