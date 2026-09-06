import hmac
from functools import wraps

import time

from flask import Flask, jsonify, render_template, request
from sqlalchemy import text

from config import API_TOKEN, HTTP_TIMEOUT, POLL_INTERVAL
from db import ENGINE
from poller import poller_status
from queries import health_rows, node_analytics, node_history, node_user_rows, summary, traffic_history, user_analytics, user_history, user_history_all, user_rows


app = Flask(__name__, static_folder="static", static_url_path="/static", template_folder="templates")
MAX_HISTORY_SECONDS = 90 * 86400


def authorized(expected_token=None):
    expected = expected_token if expected_token is not None else API_TOKEN
    if not expected:
        return True

    candidates = []
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
    failures = []
    try:
        with ENGINE.connect() as connection:
            connection.execute(text("SELECT 1"))
    except Exception:
        failures.append("database")

    state = poller_status()
    stale_after = max(POLL_INTERVAL * 3, int(POLL_INTERVAL + HTTP_TIMEOUT * 3))
    last_completed = float(state.get("last_completed") or 0)
    if (
        not last_completed
        or time.time() - last_completed > stale_after
        or state.get("last_error")
        or int(state.get("node_count") or 0) < 1
    ):
        failures.append("poller")

    status = 503 if failures else 200
    return jsonify(ok=not failures, failures=failures), status


@app.get("/api/summary")
@require_auth
def api_summary():
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    return jsonify(summary(seconds))


def _bounded_int(name, default, minimum, maximum):
    try:
        value = int(request.args.get(name, default))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


@app.get("/api/traffic")
@require_auth
def api_traffic():
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
        bucket = _bounded_int("bucket", 300, 60, 86400)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    if bucket > seconds:
        return jsonify(error="bucket must not exceed seconds"), 400
    return jsonify(traffic_history(seconds, bucket))


@app.get("/api/nodes")
@require_auth
def api_nodes():
    return jsonify(health_rows())


@app.get("/api/nodes/<node>/users")
@require_auth
def api_node_users(node):
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    return jsonify(node_user_rows(node, seconds))


@app.get("/api/nodes/<node>/analytics")
@require_auth
def api_node_analytics(node):
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
        bucket = _bounded_int("bucket", 300, 60, 86400)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    if bucket > seconds:
        return jsonify(error="bucket must not exceed seconds"), 400
    result = node_analytics(node, seconds, bucket)
    return (jsonify(result), 200) if result is not None else (jsonify(error="node not found"), 404)


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
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    return jsonify(user_rows(seconds))


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


@app.get("/api/users/<user>/analytics")
@require_auth
def api_user_analytics(user):
    try:
        seconds = _bounded_int("seconds", 86400, 3600, MAX_HISTORY_SECONDS)
        bucket = _bounded_int("bucket", 300, 60, 86400)
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    if bucket > seconds:
        return jsonify(error="bucket must not exceed seconds"), 400
    result = user_analytics(user, seconds, bucket)
    return (jsonify(result), 200) if result is not None else (jsonify(error="user not found"), 404)
