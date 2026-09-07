import os
import unittest

os.environ.setdefault("INVENTORY", "/dev/null")
os.environ.setdefault("STATS_API_TOKEN", "test-token")

from protocols import PROTOCOLS


class ProtocolsTest(unittest.TestCase):
    def test_registry_shape_is_consistent(self):
        required_keys = {"ssh_stats", "ssh_online", "local_stats", "local_online", "parse_stats", "parse_online"}
        for protocol, adapter in PROTOCOLS.items():
            self.assertEqual(set(adapter), required_keys, protocol)
            self.assertTrue(adapter["local_stats"].startswith(f"/{protocol}/"))
            self.assertTrue(adapter["local_online"].startswith(f"/{protocol}/"))
            self.assertTrue(adapter["ssh_stats"].startswith(f"{protocol}:"))
            self.assertTrue(adapter["ssh_online"].startswith(f"{protocol}:"))

    def test_xray_parse_stats_ignores_non_user_entries(self):
        raw = {"stat": [
            {"name": "user>>>alice>>>traffic>>>uplink", "value": 10},
            {"name": "user>>>alice>>>traffic>>>downlink", "value": 20},
            {"name": "inbound>>>ignored>>>traffic>>>uplink", "value": 99},
        ]}
        self.assertEqual(PROTOCOLS["xray"]["parse_stats"](raw), {"alice": {"uplink": 10, "downlink": 20}})

    def test_xray_parse_online(self):
        raw = {"users": ["alice", "user>>>bob"]}
        self.assertEqual(PROTOCOLS["xray"]["parse_online"](raw), {"alice", "bob"})

    def test_hysteria_parse_stats_maps_tx_rx_to_downlink_uplink(self):
        raw = {"alice": {"tx": 100, "rx": 50}, "bob": "not-a-dict"}
        self.assertEqual(
            PROTOCOLS["hysteria"]["parse_stats"](raw),
            {"alice": {"uplink": 50, "downlink": 100}},
        )

    def test_hysteria_parse_online_drops_zero_connection_counts(self):
        raw = {"alice": 2, "bob": 0}
        self.assertEqual(PROTOCOLS["hysteria"]["parse_online"](raw), {"alice"})


if __name__ == "__main__":
    unittest.main()
