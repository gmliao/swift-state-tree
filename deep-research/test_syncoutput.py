#!/usr/bin/env python3
"""Tests for syncoutput.py, and for the two topics' sync-output gates on their committed summaries.

Usage: python3 test_syncoutput.py
"""
import copy, importlib.util, json, pathlib, sys, tempfile, unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import syncoutput  # noqa: E402

PASSED = ("   Sync Output: passed [compared/unverifiable/skipped: broadcast 345/0/0, per-player 688/0/0, "
          "events 345/0/0, seed 2/0/0, apply 1034/0/0]\n")


def topic_regenerate(topic):
    spec = importlib.util.spec_from_file_location(f"regenerate_{topic.replace('-', '_')}", HERE / topic / "regenerate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Parse(unittest.TestCase):
    def test_a_passed_line(self):
        e = syncoutput.parse("✅ Verified state hashes\n" + PASSED)
        self.assertEqual(e["verdict"], "passed")
        self.assertEqual(e["counts"]["apply"], [1034, 0, 0])
        self.assertEqual(syncoutput.failures(syncoutput.total([e, e]), "x"), [])
        self.assertEqual(syncoutput.compared(syncoutput.total([e, e])),
                         "broadcast 690, per-player 1,376, events 690, seed 4, apply 2,068")

    def test_no_line_or_two_lines_is_refused(self):
        for text in ("nothing here\n", PASSED + PASSED):
            with self.subTest(text=text[:12]), self.assertRaises(ValueError):
                syncoutput.parse(text)

    def test_failures(self):
        cases = {
            "unverifiable": PASSED.replace("per-player 688/0/0", "per-player 688/3/0"),
            "skipped": PASSED.replace("seed 2/0/0", "seed 2/0/1"),
            "verdicts": PASSED.replace("passed", "failed"),
            "nothing compared for events": PASSED.replace("events 345/0/0", "events 0/0/0"),
            "nothing compared for apply": PASSED.replace(", apply 1034/0/0", ""),
        }
        for needle, text in cases.items():
            with self.subTest(needle):
                found = syncoutput.failures(syncoutput.total([syncoutput.parse(text)]), "x")
                self.assertTrue(any(needle in f for f in found), found)
        self.assertTrue(syncoutput.failures(syncoutput.total([]), "x"))
        bare = syncoutput.parse("Sync Output: skipped (no sync stream)\n")
        self.assertEqual(bare["verdict"], "skipped")
        self.assertTrue(syncoutput.failures(syncoutput.total([bare]), "x"))


class TopicGates(unittest.TestCase):
    """Each topic's committed sync-output.json passes its gate; a mutant of it is refused."""

    def mutated(self, topic, change):
        source = json.loads((HERE / topic / "sync-output.json").read_text(encoding="utf-8"))
        data = copy.deepcopy(source)
        change(data)
        path = pathlib.Path(tempfile.mkdtemp()) / "sync-output.json"
        self.addCleanup(lambda: (path.unlink(), path.parent.rmdir()))
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_external_input_failure(self):
        rg = topic_regenerate("external-input-failure")
        runs = rg.load(rg.RESULTS)
        self.assertEqual(sum(e["records"] for e in rg.sync_output(runs).values()), 1950)

        def unverifiable(d):
            d["runs"]["rate10-rep2"]["counts"]["per-player"][1] = 1

        def fewer(d):
            d["runs"]["join10-rep1"]["records"] -= 1
            d["runs"]["join10-rep1"]["verdicts"]["passed"] -= 1

        def missing(d):
            del d["runs"]["baseline-rep3"]

        for change in (unverifiable, fewer, missing):
            with self.subTest(change.__name__), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                rg.sync_output(runs, self.mutated("external-input-failure", change))

    def test_recomputation_cost(self):
        rg = topic_regenerate("recomputation-cost")
        runs = rg.load(rg.HERE / "results")
        groups = rg.sync_outputs(runs)
        self.assertEqual((len(groups["sizes"]), len(groups["cost"])), (12, 24))

        def skipped(d):
            next(iter(d["outputs"].values()))["counts"]["seed"][2] = 1

        def failed(d):
            next(iter(d["outputs"].values()))["verdict"] = "failed"

        def missing(d):
            del d["outputs"][sorted(k for k in d["outputs"] if k.endswith("/verify.txt"))[0]]

        for change in (skipped, failed, missing):
            with self.subTest(change.__name__), self.assertRaises(SystemExit):
                rg.sync_outputs(runs, self.mutated("recomputation-cost", change))


if __name__ == "__main__":
    unittest.main()
