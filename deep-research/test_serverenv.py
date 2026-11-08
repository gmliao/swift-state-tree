#!/usr/bin/env python3
"""Tests for serverenv.py.

Run: python3 deep-research/test_serverenv.py
"""
import pathlib
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

    def test_the_cli_prints_the_names_for_unset(self):
        out = subprocess.run([sys.executable, str(HERE / "serverenv.py")], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.split(), list(serverenv.SERVER_ENV))


if __name__ == "__main__":
    unittest.main()
