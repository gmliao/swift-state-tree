#!/usr/bin/env python3
"""Self-test of the Autobahn gate: `summarize.py --check-expected` against fixture indexes.

Run: python3 -m unittest discover -s scripts/autobahn -p 'test_*.py'
The workflow runs it before the suite.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARIZE = os.path.join(HERE, "summarize.py")
REAL_EXPECTED = os.path.join(HERE, "expected-failures.txt")
GATE_EXIT = 10

# summarize.py validates the index: one agent and exactly this many cases.
AGENT = "SwiftStateTreeNIO"
CASE_COUNT = 247
CASE_IDS = [f"1.1.{n}" for n in range(1, CASE_COUNT + 1)]


class GateTests(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.dir = self._dir.name

    def index(self, overrides=None):
        """An index of OK cases, with `overrides` ({id: (behavior, behaviorClose)}) applied."""
        cases = {cid: {"behavior": "OK", "behaviorClose": "OK", "reportfile": f"{cid}.json"}
                 for cid in CASE_IDS}
        for cid, (behavior, close) in (overrides or {}).items():
            cases[cid]["behavior"] = behavior
            cases[cid]["behaviorClose"] = close
        path = os.path.join(self.dir, "index.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({AGENT: cases}, f)
        return path

    def expected(self, text):
        path = os.path.join(self.dir, "expected-failures.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def check(self, index, expected):
        return subprocess.run(
            [sys.executable, SUMMARIZE, index, "--check-expected", expected],
            capture_output=True, text=True)

    def test_unlisted_failed_case_fails_the_gate(self):
        result = self.check(self.index({"1.1.5": ("FAILED", "OK")}), self.expected(""))
        self.assertEqual(result.returncode, GATE_EXIT, result.stderr)
        self.assertIn("1.1.5", result.stderr)

    def test_unlisted_failed_close_verdict_fails_the_gate(self):
        # `UNCLEAN` in behaviorClose counts as FAILED.
        result = self.check(self.index({"1.1.6": ("OK", "UNCLEAN")}), self.expected(""))
        self.assertEqual(result.returncode, GATE_EXIT, result.stderr)
        self.assertIn("1.1.6", result.stderr)

    def test_listed_failed_case_passes_the_gate(self):
        result = self.check(self.index({"1.1.5": ("FAILED", "OK")}),
                            self.expected("1.1.5 text-as-binary\n"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_one_unlisted_among_listed_fails_and_names_only_it(self):
        index = self.index({"1.1.5": ("FAILED", "OK"), "1.1.7": ("FAILED", "OK")})
        result = self.check(index, self.expected("1.1.5 other\n"))
        self.assertEqual(result.returncode, GATE_EXIT, result.stderr)
        self.assertIn("1.1.7", result.stderr)
        self.assertNotIn("1.1.5", result.stderr)

    def test_no_failed_case_passes_the_gate(self):
        result = self.check(self.index(), self.expected(""))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_listed_case_that_passes_is_a_warning_not_a_failure(self):
        result = self.check(self.index(), self.expected("1.1.5 other\n"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertIn("1.1.5", result.stderr)

    def test_non_strict_and_informational_never_fail_the_gate(self):
        index = self.index({"1.1.5": ("NON-STRICT", "OK"), "1.1.6": ("INFORMATIONAL", "OK"),
                            "1.1.7": ("OK", "WRONG CODE"), "1.1.8": ("UNIMPLEMENTED", "OK")})
        result = self.check(index, self.expected(""))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_comments_blank_lines_and_causes_in_the_list_are_ignored(self):
        text = "# a comment\n\n1.1.5 guess:close-code\n   \n# 1.1.9 other\n"
        result = self.check(self.index({"1.1.5": ("FAILED", "OK"), "1.1.9": ("FAILED", "OK")}),
                            self.expected(text))
        self.assertEqual(result.returncode, GATE_EXIT, result.stderr)
        self.assertIn("1.1.9", result.stderr)
        self.assertNotIn("1.1.5", result.stderr)

    def test_comments_and_blank_lines_are_not_cases(self):
        # A comment is not a listed id: no warning that something "listed" isn't FAILED.
        result = self.check(self.index({"1.1.5": ("FAILED", "OK")}),
                            self.expected("# a comment\n\n1.1.5 other\n   \n"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_a_partial_index_is_not_a_pass(self):
        path = self.index()
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        del data[AGENT][CASE_IDS[0]]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        result = self.check(path, self.expected(""))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, GATE_EXIT, "validation fails with its own code")

    def test_the_committed_list_is_well_formed(self):
        # An all-OK run against the repository's own file: it parses, and nothing is unlisted.
        result = self.check(self.index(), REAL_EXPECTED)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_missing_list_file_is_an_error(self):
        result = self.check(self.index(), os.path.join(self.dir, "missing.txt"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, GATE_EXIT)


if __name__ == "__main__":
    unittest.main()
