#!/usr/bin/env python3
"""Tests for wireform.py against this repository's history (git needed, full history).

Run: python3 deep-research/test_wireform.py
"""
import pathlib
import subprocess
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wireform  # noqa: E402

PARENT = {name: subprocess.run(["git", "-C", str(wireform.REPO), "rev-parse", "--short=8", f"{c}^"],
                               capture_output=True, text=True, check=True).stdout.strip()
          for name, c in wireform.KNOBS.items()}


class ResolveTests(unittest.TestCase):
    def test_a_recorded_knob_is_taken_as_recorded(self):
        f = wireform.resolve("49fde351", "messagepack", path_index=True, field_merge=False)
        self.assertEqual(f, wireform.WireForm("messagepack", True, False, False))
        self.assertEqual(f.caption(), "messagepack, pathIndex on, fieldMerge off")

    def test_each_knob_before_its_merge_is_off(self):
        # The commit just before #297: neither knob existed.
        self.assertEqual(wireform.resolve(PARENT["pathIndex"], "json"), wireform.WireForm("json", False, False, False))
        # The commit just before #301 contains #297, so pathIndex must be recorded; fieldMerge is off.
        self.assertEqual(wireform.resolve(PARENT["fieldMerge"], "json", path_index=True),
                         wireform.WireForm("json", True, False, False))

    def test_each_knob_at_its_merge_must_be_recorded(self):
        for name, commit in wireform.KNOBS.items():
            with self.subTest(name), self.assertRaisesRegex(wireform.MissingWireForm, f"{name} not recorded although commit {commit} contains it"):
                others = {"pathIndex": "path_index", "fieldMerge": "field_merge", "rowAddressing": "row_addressing"}
                wireform.resolve(commit, "json", **{arg: False for knob, arg in others.items() if knob != name})
        with self.assertRaisesRegex(wireform.MissingWireForm, "pathIndex not recorded although"):
            wireform.resolve(PARENT["fieldMerge"], "json")  # after #297, before #301

    def test_no_commit_or_an_unknown_one_is_missing(self):
        with self.assertRaisesRegex(wireform.MissingWireForm, "has no commit"):
            wireform.resolve(None, "json")
        with self.assertRaisesRegex(wireform.MissingWireForm, "unknown to the repository"):
            wireform.resolve("0123456789abcdef0123456789abcdef01234567", "json")
        with self.assertRaisesRegex(wireform.MissingWireForm, "encoding"):
            wireform.resolve("49fde351", None, path_index=True, field_merge=True)

    def test_a_squashed_branch_commit_resolves_through_its_merge(self):
        # Not in history itself; its squash merge predates both knobs. Short or full SHA.
        for sha in ("b8e798b", "b8e798b10679717aa"):
            with self.subTest(sha):
                self.assertEqual(wireform.resolve(sha, "messagepack-pathhash"),
                                 wireform.WireForm("messagepack-pathhash", False, False, False))
        self.assertIsNone(wireform.squashed_merge("b8e798"))  # too short to match

    def test_every_squashed_entry_is_unreachable_and_its_merge_predates_both_knobs(self):
        for branch, merge in wireform.SQUASHED.items():
            with self.subTest(branch):
                # Reachable, the map would override real ancestry.
                self.assertIsNone(wireform.contains(branch, wireform.KNOBS["pathIndex"]), f"{branch} is in history")
                for knob in wireform.KNOBS.values():
                    self.assertIs(wireform.contains(merge, knob), False, f"{merge} unknown or contains {knob}")

    def test_features_decide_the_knobs(self):
        self.assertEqual(wireform.resolve("49fde351", "messagepack", features=["pathIndex", "fieldMerge"]),
                         wireform.WireForm("messagepack", True, True, False))
        self.assertEqual(wireform.resolve("49fde351", "messagepack", features=[]),
                         wireform.WireForm("messagepack", False, False, False))
        # Not recorded: back to ancestry.
        self.assertEqual(wireform.resolve(PARENT["pathIndex"], "messagepack", features=None),
                         wireform.WireForm("messagepack", False, False, False))
        with self.assertRaises(wireform.MissingWireForm):
            wireform.resolve("49fde351", "messagepack", features="pathIndex")
        with self.assertRaises(wireform.MissingWireForm):
            wireform.resolve("49fde351", "messagepack", path_index="yes", field_merge=True)

    def test_row_addressing_is_decided_by_evidence(self):
        rows = wireform.KNOBS["rowAddressing"]
        # A recorded list decides it, before or after the default changed: an explicit on run
        # before the default, and a negotiated-off run.
        on = wireform.resolve(rows, "messagepack", features=["pathIndex", "fieldMerge", "rowAddressing", "syncSequence"])
        self.assertEqual(on, wireform.WireForm("messagepack", True, True, True))
        self.assertEqual(on.caption(), "messagepack, pathIndex on, fieldMerge on, rowAddressing on")
        self.assertEqual(wireform.resolve(rows, "messagepack", features=["pathIndex", "fieldMerge", "syncSequence"]),
                         wireform.WireForm("messagepack", True, True, False))
        # A caller that knows the run couldn't have it passes it (EncodingBenchmark's local path).
        self.assertEqual(wireform.resolve(rows, "messagepack-pathhash", path_index=True, field_merge=True, row_addressing=False),
                         wireform.WireForm("messagepack-pathhash", True, True, False))
        # No list and no value: off before the feature came in, missing from it on.
        self.assertFalse(wireform.resolve(PARENT["rowAddressing"], "messagepack", path_index=True, field_merge=True).row_addressing)
        with self.assertRaisesRegex(wireform.MissingWireForm, "rowAddressing not recorded although"):
            wireform.resolve(rows, "messagepack", path_index=True, field_merge=True)
        with self.assertRaisesRegex(wireform.MissingWireForm, "unknown to the repository"):
            wireform.resolve("0123456789abcdef0123456789abcdef01234567", "messagepack", path_index=True, field_merge=True)
        with self.assertRaises(ValueError):
            wireform.resolve(rows, "messagepack", features=[], row_addressing=False)
        # Off, the caption reads as before the field existed.
        self.assertEqual(wireform.WireForm("json", False, False, False).caption(), "json, pathIndex off, fieldMerge off")

    def test_join_counts_give_one_wire_form_or_a_mixed_run(self):
        self.assertEqual(wireform.join_form({"messagepack:fieldMerge,pathIndex": 40}), ("messagepack", ["fieldMerge", "pathIndex"]))
        self.assertEqual(wireform.join_form({"json:none": 3, "messagepack:pathIndex": 0}), ("json", []))
        self.assertEqual(wireform.join_form({"unknown:none": 2}), (None, []))
        self.assertIsNone(wireform.join_form({}))
        self.assertIsNone(wireform.join_form(None))
        for counts, text in (({"messagepack:none": 1, "messagepack:fieldMerge,pathIndex": 39}, "different wire forms"),
                             ({"fieldMerge,pathIndex": 4}, "has no encoding")):
            with self.subTest(text), self.assertRaisesRegex(wireform.MissingWireForm, text):
                wireform.join_form(counts)

    def test_check_lists_each_run_off_the_intended_form(self):
        on = wireform.WireForm("messagepack", True, True, False)
        off = wireform.WireForm("messagepack", False, False, False)
        self.assertEqual(wireform.check({"a": on, "b": on}, on), [])
        self.assertEqual(wireform.check({"b": off, "a": on}, on),
                         ["b: messagepack, pathIndex off, fieldMerge off, intended messagepack, pathIndex on, fieldMerge on"])


if __name__ == "__main__":
    unittest.main()
