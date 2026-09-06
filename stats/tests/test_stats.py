import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


TEST_DIR = tempfile.TemporaryDirectory()
TEST_ROOT = Path(TEST_DIR.name)
INVENTORY_PATH = TEST_ROOT / "inventory.json"
INVENTORY_PATH.write_text(json.dumps({
    "stats": {"master_node": "node-a", "node_port": 9091},
    "nodes": [{"name": "node-a", "host": "127.0.0.1"}],
}))
os.environ["INVENTORY"] = str(INVENTORY_PATH)
os.environ["STATS_DB"] = str(TEST_ROOT / "stats.sqlite3")
os.environ["STATS_ACTIVE_DURATION"] = "1"
os.environ["STATS_API_TOKEN"] = "test-token"
os.environ["STATS_MIN_ACTIVITY_BYTES"] = "1"
os.environ["STATS_ONLINE_WINDOW"] = "30"

from sqlalchemy import delete

from db import init_db, session_scope
from httpserver import app
from models import Health, PollRun, Previous, Sample, Total
from poller import accumulate, parse_online, parse_stats
from queries import node_analytics, node_history, node_user_rows, traffic_history, user_analytics, user_rows


class StatsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        init_db()

    def setUp(self):
        with session_scope() as session:
            for model in (Sample, PollRun, Previous, Total, Health):
                session.execute(delete(model))

    def test_parse_stats_and_online_formats(self):
        raw = {"stat": [
            {"name": "user>>>alice>>>traffic>>>uplink", "value": 10},
            {"name": "user>>>alice>>>traffic>>>downlink", "value": 20},
            {"name": "inbound>>>ignored>>>traffic>>>uplink", "value": 99},
        ]}
        self.assertEqual(parse_stats(raw), {"alice": {"uplink": 10, "downlink": 20}})
        self.assertEqual(parse_online({"users": ["alice", "user>>>bob"]}), {"alice", "bob"})

    def test_missing_user_is_marked_inactive(self):
        accumulate("node-a", {
            "alice": {"uplink": 10, "downlink": 20},
            "bob": {"uplink": 10, "downlink": 20},
        }, {"alice", "bob"})
        accumulate("node-a", {
            "alice": {"uplink": 20, "downlink": 40},
            "bob": {"uplink": 20, "downlink": 40},
        }, {"alice", "bob"})
        accumulate("node-a", {
            "alice": {"uplink": 30, "downlink": 60},
        }, {"alice"})

        with session_scope() as session:
            bob = session.get(Total, ("node-a", "bob"))
            previous = session.get(Previous, ("node-a", "bob"))
            self.assertFalse(bob.active)
            self.assertFalse(bob.online)
            self.assertFalse(previous.was_active)

    def test_online_requires_node_health_and_raw_online_signal(self):
        now = int(time.time())
        with session_scope() as session:
            session.add(Health(node="node-a", ok=True, latency_ms=1, error="", ts=now))
            session.add(Total(
                node="node-a", user_name="alice", uplink=10, downlink=20,
                online=False, active=True, active_since=now - 5,
                active_bytes=30, last_seen=now,
            ))
        self.assertFalse(node_user_rows("node-a")[0]["online"])

        with session_scope() as session:
            session.get(Total, ("node-a", "alice")).online = True
        self.assertTrue(node_user_rows("node-a")[0]["online"])

        with session_scope() as session:
            session.get(Health, "node-a").ok = False
        row = node_user_rows("node-a")[0]
        self.assertFalse(row["available"])
        self.assertFalse(row["online"])

    def test_node_history_limits_grouped_poll_intervals(self):
        with session_scope() as session:
            for timestamp in (100, 200, 300):
                session.add(Sample(node="node-a", user_name="alice", ts=timestamp, uplink=1, downlink=2))
                session.add(Sample(node="node-a", user_name="bob", ts=timestamp, uplink=3, downlink=4))

        history = node_history("node-a", limit=2)
        self.assertEqual([item["ts"] for item in history], [200, 300])
        self.assertEqual(history[0]["uplink"], 4)
        self.assertEqual(history[0]["downlink"], 6)

    def test_query_token_is_rejected(self):
        client = app.test_client()
        self.assertEqual(client.get("/api/summary?token=test-token").status_code, 401)
        response = client.get("/api/summary", headers={"X-Stats-Token": "test-token"})
        self.assertEqual(response.status_code, 200)

    def test_period_traffic_is_aggregated_per_user(self):
        with session_scope() as session:
            session.add(Total(node="node-a", user_name="alice", uplink=100, downlink=200))
            session.add(Sample(node="node-a", user_name="alice", ts=150, uplink=4, downlink=6))
            session.add(Sample(node="node-a", user_name="alice", ts=50, uplink=40, downlink=60))
        with patch("queries.time.time", return_value=200):
            row = user_rows(period_seconds=100)[0]
        self.assertEqual(row["period_uplink"], 4)
        self.assertEqual(row["period_downlink"], 6)
        self.assertEqual(row["period_total"], 10)

    def test_traffic_history_distinguishes_idle_and_missing_buckets(self):
        with session_scope() as session:
            session.add(Sample(node="node-a", user_name="alice", ts=125, uplink=4, downlink=6))
            session.add(PollRun(node="node-a", ok=True, latency_ms=1, error="", ts=125))
        with patch("queries.time.time", return_value=180):
            series = traffic_history(seconds=120, bucket=60)["series"]
        self.assertIsNone(series[0]["total"])
        self.assertEqual(series[1]["total"], 10)
        self.assertEqual(series[1]["coverage"], 1.0)
        self.assertIsNone(series[2]["total"])

    def test_node_and_user_analytics(self):
        with session_scope() as session:
            session.add(Total(node="node-a", user_name="alice", uplink=4, downlink=6))
            session.add(Sample(node="node-a", user_name="alice", ts=125, uplink=4, downlink=6))
            session.add(PollRun(node="node-a", ok=True, latency_ms=20, error="", ts=125))
            session.add(PollRun(node="node-a", ok=False, latency_ms=40, error="timeout", ts=150))
        with patch("queries.time.time", return_value=180):
            node = node_analytics("node-a", seconds=120, bucket=60)
            user = user_analytics("alice", seconds=120, bucket=60)
        self.assertEqual(node["active_users"], 1)
        self.assertEqual(node["successful_polls"], 1)
        self.assertEqual(node["polls"], 2)
        self.assertEqual(node["availability"], 0.5)
        self.assertEqual(node["average_latency_ms"], 30.0)
        self.assertEqual(user["active_nodes"], 1)

    def test_api_history_range_is_capped_at_90_days(self):
        client = app.test_client()
        headers = {"X-Stats-Token": "test-token"}
        accepted = client.get("/api/traffic?seconds=7776000&bucket=86400", headers=headers)
        rejected = client.get("/api/traffic?seconds=7862400&bucket=86400", headers=headers)
        self.assertEqual(accepted.status_code, 200)
        self.assertEqual(rejected.status_code, 400)


if __name__ == "__main__":
    unittest.main()
