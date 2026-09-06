import os

from waitress import serve

from . import create_app


def main() -> None:
    bind = os.environ.get("WEB_BIND", "127.0.0.1")
    port = int(os.environ.get("WEB_PORT", "9095"))
    serve(create_app(), host=bind, port=port, threads=4)


if __name__ == "__main__":
    main()
