#!/usr/bin/env python3
"""Tests for provenance.py (stdlib only): python3 test_provenance.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import provenance  # noqa: E402
from provenance import Meta, Refused  # noqa: E402

FULL = "ca904c8c" + "0" * 32


class Line(unittest.TestCase):
    def test_one_commit_clean_with_every_field(self):
        metas = [Meta("a.json", FULL, False, "Swift version 6.2.4 (swift-6.2.4-RELEASE)", "v24.22.2", "release"),
                 Meta("b.json", FULL, False, "Swift version 6.2.4 (swift-6.2.4-RELEASE)", "v24.22.2", "release")]
        self.assertEqual(provenance.line(metas),
                         f"Provenance, from the results' meta: commit `{FULL}`, clean tree; Swift 6.2.4; Node v24.22.2; build release.")

    def test_a_short_commit_prints_as_recorded_and_missing_fields_say_so(self):
        self.assertEqual(provenance.line([Meta("a.json", "986097b7", swift="Swift 6.2.4")], label="3.0"),
                         "Provenance (3.0), from the results' meta: commit `986097b7`, dirty flag not recorded; "
                         "Swift 6.2.4; Node not recorded; build not recorded.")

    def test_fields_recorded_by_some_results_only_and_differing_values(self):
        metas = [Meta("a", FULL, False, "6.2.4", None, "release"), Meta("b", FULL, None, None, "v24.22.2", "debug")]
        text = provenance.line(metas)
        self.assertIn("clean tree (not recorded in 1 of 2)", text)
        self.assertIn("Swift 6.2.4 (not recorded in 1 of 2)", text)
        self.assertIn("Node v24.22.2 (not recorded in 1 of 2)", text)
        self.assertIn("build debug / release.", text)

    def test_a_scoped_field_reads_only_its_kinds(self):
        metas = [Meta("sst.json", FULL, False, "6.2.4", "v24.22.2", "release", kind="sst"),
                 Meta("b1.json", FULL, False, None, "v24.22.2", None, kind="b1")]
        scopes = {"swift": ("SST runs", {"sst"}), "build": ("SST runs", {"sst"})}
        self.assertEqual(provenance.line(metas, scopes=scopes),
                         f"Provenance, from the results' meta: commit `{FULL}`, clean tree; Swift 6.2.4 (SST runs); "
                         "Node v24.22.2; build release (SST runs).")

    def test_a_topic_without_node_leaves_it_out(self):
        self.assertEqual(provenance.line([Meta("a", FULL, False, "6.2.4", None, "release")], node=False),
                         f"Provenance, from the results' meta: commit `{FULL}`, clean tree; Swift 6.2.4; build release.")

    def test_no_results_no_line(self):
        self.assertIsNone(provenance.line([]))

    def test_refuses_a_missing_commit_mixed_commits_and_a_dirty_tree(self):
        cases = {
            "missing": ([Meta("a.json", None)], "a.json: no commit"),
            "empty": ([Meta("a.json", "")], "a.json: no commit"),
            "mixed": ([Meta("a", "aaaa111"), Meta("b", "bbbb222")], r"results from 2 commits \(aaaa111, bbbb222\)"),
            "dirty": ([Meta("a", FULL, False), Meta("b.json", FULL, True)], "b.json: measured on a dirty tree"),
        }
        for name, (metas, pattern) in cases.items():
            with self.subTest(name), self.assertRaisesRegex(Refused, pattern):
                provenance.line(metas)


class FromResults(unittest.TestCase):
    def test_reads_the_collectors_snake_case_meta(self):
        runs = [{"meta": {"source_file": "a.json", "git_sha": FULL, "git_dirty": False, "swift_version": "6.2.4",
                          "node_version": "v24.22.2", "build_config": "release"}, "params": {"variant": "sst"}},
                {"meta": {}}]
        metas = provenance.from_results(runs, kind=lambda r: (r.get("params") or {}).get("variant", ""))
        self.assertEqual(metas[0], Meta("a.json", FULL, False, "6.2.4", "v24.22.2", "release", kind="sst"))
        self.assertEqual(metas[1], Meta("a result", None))


class SwiftDisplay(unittest.TestCase):
    def test_forms(self):
        for recorded, shown in (("Swift version 6.2.4 (swift-6.2.4-RELEASE)", "6.2.4"), ("Swift 6.2.4", "6.2.4"), ("Swift version 6.2.4", "6.2.4"),
                                ("6.2.4", "6.2.4"), ("Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-1700.3.19.1)",
                                                     "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-1700.3.19.1)"),
                                ("Swift version 6.3-dev", "Swift version 6.3-dev")):
            with self.subTest(recorded):
                self.assertEqual(provenance.swift_display(recorded), shown)


if __name__ == "__main__":
    unittest.main()
