#!/usr/bin/env python3
"""Tests for portable.py (stdlib only): python3 test_portable.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import portable  # noqa: E402

ROOT = "/workspace/checkout"


class CheckoutRelative(unittest.TestCase):
    def test_paths_under_the_root_lose_the_root(self):
        cases = {
            f"GAMESERVER_BIN={ROOT}/Examples/GameDemo/.build/release/GameServer":
                "GAMESERVER_BIN=Examples/GameDemo/.build/release/GameServer",
            f"node v24.22.2\nexternal server binary {ROOT}/Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer\n":
                "node v24.22.2\nexternal server binary Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer\n",
            f'"{ROOT}/Sources/A.swift"': '"Sources/A.swift"',
        }
        for given, wanted in cases.items():
            with self.subTest(given):
                self.assertEqual(portable.checkout_relative(given, ROOT), wanted)
                self.assertEqual(portable.checkout_relative(given, ROOT + "/"), wanted)
                self.assertEqual(portable.absolute_paths(portable.checkout_relative(given, ROOT)), [])

    def test_paths_outside_the_root_stay_visible(self):
        # A path that only contains a repository directory name isn't in the checkout.
        for text in ("/usr/local/lib/node_modules/npm/scripts/postinstall.js", "/opt/homebrew/share/docs/x",
                     "/srv/build/Tools/ws-loadtest/dist/index.js", "/home/me/scripts/swift-state-tree/Examples/GameDemo/x",
                     f"{ROOT}x/Examples/y", f"/home/other{ROOT}/Examples/y", "/tmp/ws-loadtest-gameserver.log"):
            with self.subTest(text):
                self.assertEqual(portable.checkout_relative(text, ROOT), text)
                self.assertTrue(portable.checkout_relative(text, ROOT).startswith("/"), text)

    def test_relativize_leaves_keys_and_other_paths(self):
        doc = {f"{ROOT}/key": f"{ROOT}/Examples/G", "runs": [{"log": "/tmp/x.log"}], "n": 3}
        self.assertEqual(portable.relativize(doc, ROOT), {f"{ROOT}/key": "Examples/G", "runs": [{"log": "/tmp/x.log"}], "n": 3})


class Root(unittest.TestCase):
    def test_recorded_root_else_override_else_refused(self):
        self.assertEqual(portable.checkout_root({"git": {"root": ROOT + "/"}}, None, "x"), ROOT)
        self.assertEqual(portable.checkout_root({"git": {}}, ROOT, "x"), ROOT)
        self.assertEqual(portable.checkout_root({"git": {"root": ROOT}}, ROOT + "/", "x"), ROOT)
        for record, override, text in (({}, None, "pass --checkout-root"), ({"git": {"root": ROOT}}, "/elsewhere", "isn't --checkout-root"),
                                       ({}, "relative/dir", "isn't an absolute"), ({}, "/", "isn't an absolute")):
            with self.subTest(override), self.assertRaises(SystemExit) as cm:
                portable.checkout_root(record, override, "x")
            self.assertIn(text, str(cm.exception))


if __name__ == "__main__":
    unittest.main()
