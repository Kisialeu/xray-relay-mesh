from flask import Flask, jsonify, render_template


def register_routes(app: Flask) -> None:
    @app.get("/")
    def index():
        return render_template("index.html")

    @app.get("/healthz")
    def healthz():
        return jsonify(ok=True)
