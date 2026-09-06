import hmac
from functools import wraps

from flask import Flask, jsonify, render_template, request

from config import API_TOKEN
from queries import health_rows, node_history, node_user_rows, summary, user_history, user_history_all


app = Flask(__name__, static_folder="static", static_url_path="/static", template_folder="templates")


def authorized(expected_token=None):
    expected = expected_token if expected_token is not None else API_TOKEN
    if not expected:
        return True

    candidates = [request.args.get("token", "")]
    header_token = request.headers.get("X-Stats-Token", "")
    if header_token:
        candidates.append(header_token)
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        candidates.append(auth[len("Bearer "):])
    return any(hmac.compare_digest(candidate, expected) for candidate in candidates if candidate)


def require_auth(view):
    @wraps(view)
    def protected(*args, **kwargs):
        if not authorized():
            return jsonify(error="unauthorized"), 401
        return view(*args, **kwargs)

    return protected


@app.get("/xray")
@app.get("/xray/")
def xray_page():
    return render_template("xray.html")


@app.get("/users/<path:route>")
def user_page(route):
    return render_template("user.html")


@app.get("/nodes/<path:route>")
def node_page(route):
    return render_template("node.html")


@app.get("/api/health")
def health():
    return jsonify(ok=True)


@app.get("/api/summary")
@require_auth
def api_summary():
    return jsonify(summary())


@app.get("/api/nodes")
@require_auth
def api_nodes():
    return jsonify(health_rows())


@app.get("/api/nodes/<node>/users")
@require_auth
def api_node_users(node):
    return jsonify(node_user_rows(node))


@app.get("/api/nodes/<node>/history")
@require_auth
def api_node_history(node):
    try:
        limit = int(request.args.get("limit", 500))
    except (TypeError, ValueError):
        return jsonify(error="limit must be an integer"), 400
    return jsonify(node_history(node, limit))


@app.get("/api/users")
@require_auth
def api_users():
    return jsonify(summary()["users"])


@app.get("/api/users/<node>/<user>/history")
@require_auth
def api_user_history(node, user):
    try:
        limit = int(request.args.get("limit", 96))
    except (TypeError, ValueError):
        return jsonify(error="limit must be an integer"), 400
    return jsonify(user_history(node, user, limit))


@app.get("/api/users/<user>/history")
@require_auth
def api_global_user_history(user):
    try:
        limit = int(request.args.get("limit", 500))
    except (TypeError, ValueError):
        return jsonify(error="limit must be an integer"), 400
    return jsonify(user_history_all(user, limit))
