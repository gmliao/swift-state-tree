#!/usr/bin/env python3
"""Tests for toolchain-643-aa-baseline: the README matches results/, and the classes hold."""
import csv
import pathlib
import subprocess
import sys
import unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import regenerate  # noqa: E402


class TopicTests(unittest.TestCase):
    def test_readme_matches_results(self):
        result = subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--check"],
                                capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_cell_has_five_reps_per_side(self):
        with open(TOPIC / "results" / "per-op.csv", newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        keys = {}
        for r in rows:
            keys.setdefault((r["bench"], r["cell"], r["impl"], r["side"]), set()).add(r["rep"])
        self.assertEqual(len(keys), (13 * 2 + 2 * 2) * 2)
        for key, reps in keys.items():
            self.assertEqual(reps, {"1", "2", "3", "4", "5"}, key)

    def test_whole_process_runs_all_exited_zero(self):
        with open(TOPIC / "results" / "whole-process.csv", newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        self.assertEqual(len(rows), 20)
        self.assertEqual({r["exit"] for r in rows}, {"0"})

    def test_classify(self):
        self.assertEqual(regenerate.classify((100.0, 0.0001), (100.01, 0.0002)), ("tight", 0.0002))
        cls, floor = regenerate.classify((100.0, 0.01), (100.0, 0.0))
        self.assertEqual((cls, round(floor, 6)), ("noisy", 0.01))
        self.assertEqual(regenerate.classify((0.2, 3.0), (100.0, 0.0)), ("not measurable", None))

    def test_check_fails_on_a_changed_table(self):
        text = regenerate.README.read_text(encoding="utf-8")
        changed = text.replace("| tight |", "| noisy |", 1)
        self.assertNotEqual(text, changed)
        start = changed.find(regenerate.BEGIN) + len(regenerate.BEGIN)
        end = changed.find(regenerate.END)
        self.assertNotEqual(changed[start:end].strip("\n"), regenerate.markdown())


if __name__ == "__main__":
    unittest.main()
