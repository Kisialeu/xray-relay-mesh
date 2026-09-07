from flask import Flask


def create_app() -> Flask:
    app = Flask(__name__, static_folder="static", template_folder="templates")

    from .routes import register_routes

    register_routes(app)
    return app
