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

    def test_the_added_sync_path_switches_are_unset_recorded_and_refused(self):
        # #468/#489: USE_SYNC_TABLES (#465), ROW_ADDRESSING (#487) and SYNC_STRATEGY change the sync
        # path or what it sends; run.sh unsets them with the rest, runmeta records them, and a run with
        # one set is refused, whatever its value.
        for name in ("USE_SYNC_TABLES", "ROW_ADDRESSING", "SYNC_STRATEGY", "OUTBOUND_WRITER_MAX_BYTES", "JOIN_FLIP_BUDGET",
                     "CHANGE_OBJECT_METRICS_EMA_ALPHA"):
            self.assertIn(name, serverenv.SERVER_ENV)
            self.assertIsNone(serverenv.record({})[name])
            self.assertEqual(serverenv.record({name: "true"})[name], "true")
            for value in ("true", "false", "full-snapshot"):
                with self.subTest(name=name, value=value):
                    self.assertIn(f"'{name}': '{value}'", serverenv.failure("x", serverenv.record({name: value})))

    def test_a_record_from_before_the_sync_tables_switch_is_accepted(self):
        # Every published record predates it: lacking the key isn't a refusal, as for ADDED.
        old = {k: None for k in serverenv.SERVER_ENV if k not in serverenv.ADDED_SYNC_PATH}
        self.assertIsNone(serverenv.failure("x", old))
        older = {k: None for k in serverenv.SERVER_ENV if k not in serverenv.ADDED and k not in serverenv.ADDED_SYNC_PATH}
        self.assertIsNone(serverenv.failure("x", older))
        self.assertTrue(set(serverenv.ADDED_SYNC_PATH) <= set(serverenv.SERVER_ENV))

    # Every server variable that isn't a sync-path or wire switch, by kind. A key the server reads
    # must be in SERVER_ENV (unset, recorded, refused) or here, so a new key fails until it's
    # classified: the bug class of #468, a switch that changes the sync path or the wire with no
    # record. TRANSPORT_ENCODING is outside both: the topics set it explicitly and record it.
    NOT_SYNC_OR_WIRE = {
        # reevaluation and recording
        "REEVALUATION_RECORDS_DIR", "REEVALUATION_RECORD_SYNC_DETAILS", "REEVALUATION_RECORD_SYNC_PATCHES",
        "REEVALUATION_SPOOL_DIR", "ENABLE_STATE_SNAPSHOT_RECORDING",
        # debug routes and deadlines
        "ENABLE_DEBUG_STATE_ROUTES", "DEBUG_FREEZE_TIMEOUT_SECONDS", "RESOLVER_TIMEOUT_MS", "RESOLVER_INIT_TIMEOUT_MS",
        # the land loop's phase and the process (threads, listen backlog, logging)
        "LAND_LOOP_PHASE_OFFSET", "LISTEN_BACKLOG", "EVENT_LOOP_THREADS", "LOG_USE_COLORS", "NO_COLOR",
        "GENERIC_REPLAY_DEBUG",
        # transport bounds: the topics record the send backlog themselves (sendBacklogEnv)
        "WS_PONG_TIMEOUT_MS", "WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS",
        "WS_INBOUND_BACKLOG_MAX_MESSAGES", "WS_INBOUND_BACKLOG_MAX_BYTES", "FINAL_FRAME_CLOSE_TIMEOUT_MS",
        # joins (JOIN_FLIP_BUDGET changes what a sync sends: it's in SERVER_ENV). The held-event and
        # deferred-inbound bounds decide whether a join succeeds: over them the join fails
        # (eventOverflow, inboundOverflow) or a flipped session is closed with an error frame, all
        # counted. They never change the frames sent to sessions that stay. OUTBOUND_WRITER_MAX_BYTES
        # does: it drops a sync frame that later diffs build on, and its recovery (a disconnect, a
        # rejoin and a fresh firstSync) changes the sync stream of a run that carries on.
        "JOIN_TIMEOUT_MS", "JOIN_FLIP_TIMEOUT_MS", "JOIN_HELD_EVENTS_MAX", "JOIN_HELD_EVENTS_MAX_BYTES",
        "JOIN_DEFERRED_INBOUND_MAX", "JOIN_DEFERRED_INBOUND_MAX_BYTES",
        # metrics and profiling (they observe the path, they don't change it). ENABLE_CHANGE_OBJECT_METRICS
        # only adds the collection and its log: the dirty-tracking switch is AUTO_DIRTY_TRACKING's. The
        # EMA's alpha feeds that switch, so it's in SERVER_ENV.
        "ENABLE_CHANGE_OBJECT_METRICS", "CHANGE_OBJECT_METRICS_LOG_EVERY",
        "LAND_LIFECYCLE_LOG_PATH", "TRANSPORT_PROFILE_JSONL_PATH", "TRANSPORT_PROFILE_INTERVAL_MS",
        "TRANSPORT_PROFILE_SAMPLE_RATE", "TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL",
        # other products: the diff benchmark, auth, provisioning
        "DIFF_BENCHMARK_MODE", "JWT_SECRET_KEY", "JWT_ALGORITHM", "JWT_ISSUER", "JWT_AUDIENCE",
        "PROVISIONING_BASE_URL", "PROVISIONING_SERVER_ID", "PROVISIONING_HEARTBEAT_INTERVAL_SECONDS",
        "PROVISIONING_CONNECT_HOST", "PROVISIONING_CONNECT_PORT", "PROVISIONING_CONNECT_SCHEME",
    }

    @staticmethod
    def server_keys():
        """Every variable name the server reads: string keys in the *EnvKeys* enums, any
        `environmentKey = "..."` declared elsewhere (SYNC_STRATEGY, in SyncStrategy.swift), and any
        name read by literal: an env helper's `key: "..."` (GENERIC_REPLAY_DEBUG), `environment["..."]`
        or `getenv("...")`."""
        root = HERE.parent / "Sources"
        keys = set()
        for path in root.rglob("*EnvKeys*.swift"):
            keys |= set(re.findall(r'static let \w+ = "([A-Z][A-Z0-9_]*)"', path.read_text(encoding="utf-8")))
        for path in root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            keys |= set(re.findall(r'environmentKey = "([A-Z][A-Z0-9_]*)"', text))
            keys |= set(re.findall(r'(?:\bkey:\s*|environment\[\s*|getenv\(\s*)"([A-Z][A-Z0-9_]*)"', text))
        return keys

    def test_every_server_variable_is_classified(self):
        keys = self.server_keys()
        self.assertTrue({"USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "PATH_INDEX", "SYNC_STRATEGY", "GENERIC_REPLAY_DEBUG"} <= keys, f"the scan is broken: {sorted(keys)}")
        unclassified = keys - set(serverenv.SERVER_ENV) - self.NOT_SYNC_OR_WIRE
        self.assertEqual(unclassified, set(), "a new server variable: list it in serverenv.SERVER_ENV if it changes "
                                              "the sync path or the wire, else in NOT_SYNC_OR_WIRE")
        self.assertEqual(self.NOT_SYNC_OR_WIRE & set(serverenv.SERVER_ENV), set())

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
