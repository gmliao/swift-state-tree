#!/usr/bin/env python3
"""Tests for serverenv.py.

Run: python3 deep-research/test_serverenv.py
"""
import pathlib
import re
import subprocess
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import serverenv  # noqa: E402


class ServerEnvTests(unittest.TestCase):
    def test_record_names_every_variable(self):
        env = serverenv.record({"USE_SNAPSHOT_FOR_SYNC": "false", "UNRELATED": "1"})
        self.assertEqual(set(env), set(serverenv.SERVER_ENV))
        self.assertEqual(env["USE_SNAPSHOT_FOR_SYNC"], "false")
        self.assertIsNone(env["PATH_INDEX"])

    def test_all_unset_passes(self):
        self.assertIsNone(serverenv.failure("x", serverenv.record({})))

    def test_refusals(self):
        for name in serverenv.SERVER_ENV:
            with self.subTest(name):
                self.assertIn(f"'{name}': 'false'", serverenv.failure("x", serverenv.record({name: "false"})))
        self.assertIn("not recorded", serverenv.failure("x", None))
        partial = serverenv.record({})
        del partial["IN_TURN_SYNC"]
        self.assertIn("lacks ['IN_TURN_SYNC']", serverenv.failure("x", partial))

    def test_the_action_job_caps_and_sync_lag_are_unset_and_refused(self):
        for name in ("ACTION_IN_FLIGHT_MAX_PER_SESSION", "RESOLVER_ABANDONED_ACTIONS_MAX", "SYNC_LAG_RESYNC_MS",
                     "SYNC_ACK_TIMEOUT_MS", "SYNC_LAG_CLOSE_GRACE_MS"):
            with self.subTest(name):
                self.assertIn(name, serverenv.SERVER_ENV)
                self.assertIn(f"'{name}': '1'", serverenv.failure("x", serverenv.record({name: "1"})))

    def test_a_record_from_before_the_added_variables_is_accepted(self):
        old = {k: None for k in serverenv.SERVER_ENV if k not in serverenv.ADDED}
        self.assertIsNone(serverenv.failure("x", old))
        self.assertTrue(set(serverenv.ADDED) <= set(serverenv.SERVER_ENV))

    def test_the_sync_tables_switch_is_unset_recorded_and_refused(self):
        # #468: USE_SYNC_TABLES (#465) changes the sync path; run.sh unsets it with the rest, runmeta
        # records it, and a run with it set is refused, whatever its value.
        self.assertIn("USE_SYNC_TABLES", serverenv.SERVER_ENV)
        self.assertIsNone(serverenv.record({})["USE_SYNC_TABLES"])
        self.assertEqual(serverenv.record({"USE_SYNC_TABLES": "true"})["USE_SYNC_TABLES"], "true")
        for value in ("true", "false", "1"):
            with self.subTest(value):
                self.assertIn(f"'USE_SYNC_TABLES': '{value}'", serverenv.failure("x", serverenv.record({"USE_SYNC_TABLES": value})))

    def test_a_record_from_before_the_sync_tables_switch_is_accepted(self):
        # Every published record predates it: lacking the key isn't a refusal, as for ADDED.
        old = {k: None for k in serverenv.SERVER_ENV if k not in serverenv.ADDED_SYNC_TABLES}
        self.assertIsNone(serverenv.failure("x", old))
        older = {k: None for k in serverenv.SERVER_ENV if k not in serverenv.ADDED and k not in serverenv.ADDED_SYNC_TABLES}
        self.assertIsNone(serverenv.failure("x", older))
        self.assertTrue(set(serverenv.ADDED_SYNC_TABLES) <= set(serverenv.SERVER_ENV))

    def test_every_sync_path_switch_the_server_reads_is_listed(self):
        # The bug class of #468: a new switch that changes the sync path must join SERVER_ENV, or a
        # shell with it set runs another path unrecorded. Today USE_SNAPSHOT_FOR_SYNC and
        # IN_TURN_SYNC; USE_SYNC_TABLES once #465 lands.
        root = HERE.parent / "Sources"
        keys = set()
        for path in root.rglob("*EnvKeys*.swift"):
            keys |= set(re.findall(r'"(USE_[A-Z_]*SYNC[A-Z_]*|IN_TURN_SYNC)"', path.read_text(encoding="utf-8")))
        self.assertTrue({"USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC"} <= keys, f"the scan is broken: {keys}")
        self.assertEqual(keys - set(serverenv.SERVER_ENV), set())

    def test_every_sync_lag_and_action_cap_key_the_server_reads_is_listed(self):
        root = HERE.parent / "Sources"
        keys = set()
        for path in root.rglob("*EnvKeys*.swift"):
            keys |= set(re.findall(r'"((?:SYNC_LAG|SYNC_ACK)_[A-Z_]+|ACTION_IN_FLIGHT_[A-Z_]+|RESOLVER_ABANDONED_[A-Z_]+)"',
                                   path.read_text(encoding="utf-8")))
        self.assertTrue(keys, "no keys found: the scan is broken")
        self.assertEqual(keys - set(serverenv.SERVER_ENV), set())

    def test_the_cli_prints_the_names_for_unset(self):
        out = subprocess.run([sys.executable, str(HERE / "serverenv.py")], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.split(), list(serverenv.SERVER_ENV))


if __name__ == "__main__":
    unittest.main()
