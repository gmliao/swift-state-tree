#!/usr/bin/env python3
"""Tests for portable.py (stdlib only): python3 test_portable.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import portable  # noqa: E402


class CheckoutRelative(unittest.TestCase):
    def test_paths_into_the_checkout_lose_the_checkout(self):
        cases = {
            "GAMESERVER_BIN=/workspace/checkout/Examples/GameDemo/.build/release/GameServer":
                "GAMESERVER_BIN=Examples/GameDemo/.build/release/GameServer",
            "external server binary /workspace/checkout/Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer":
                "external server binary Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer",
            "/home/u/src/repo/deep-research/x/raw/r1": "deep-research/x/raw/r1",
            "a\n/Users/me/c/Tools/CLI/x.sh y\nb": "a\nTools/CLI/x.sh y\nb",
            '"/workspace/w/Sources/A.swift"': '"Sources/A.swift"',
        }
        for given, wanted in cases.items():
            with self.subTest(given):
                self.assertEqual(portable.checkout_relative(given), wanted)
                self.assertEqual(portable.absolute_paths(portable.checkout_relative(given)), [])

    def test_other_text_and_relative_paths_stay(self):
        for text in ("Examples/GameDemo/.build/release/GameServer", "node v24.22.2", "/proc/123/exe", "a/b/Examples/c",
                     "https://example.org/Examples/x"):
            with self.subTest(text):
                self.assertEqual(portable.checkout_relative(text), text)

    def test_relativize_walks_json_and_absolute_paths_finds_whats_left(self):
        doc = {"bin": "/workspace/w/Examples/G/GameServer", "runs": [{"log": "/tmp/x.log"}], "n": 3}
        self.assertEqual(portable.relativize(doc), {"bin": "Examples/G/GameServer", "runs": [{"log": "/tmp/x.log"}], "n": 3})
        self.assertEqual(portable.absolute_paths(portable.relativize(doc)), ["/tmp/x.log"])


if __name__ == "__main__":
    unittest.main()
