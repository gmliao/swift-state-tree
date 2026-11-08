#!/usr/bin/env python3
"""Tests for run.sh (dry run), collect.py and regenerate.py, with no build: a synthetic sweep in a
temporary directory.

Usage: python3 test_topic.py
"""
import json, os, pathlib, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import collect, regenerate  # noqa: E402

FLAGS = {"sst-events": [], "sst": ["--no-server-events"], "b2": ["--baseline", "entity-delta", "--no-server-events"]}


def benchmark(variant, rooms, players, bytes_per_sync, cap=None, active=False):
    cmd = [".build/release/EncodingBenchmark", "--scalability", "--format", "messagepack-pathhash", "--sync-strategy", "delta",
           "--iterations", "200", "--ticks-per-sync", "2", "--parallel", "false", *FLAGS[variant],
           "--players-per-room-list", str(players), "--room-counts", str(rooms)]
    if cap is not None:
        cmd += ["--monster-cap", str(cap)]
    if active:
        cmd.append("--active-players")
    serial = {"bytesPerSync": int(bytes_per_sync), "totalBytes": bytes_per_sync * 200, "syncMs": 2.0 * rooms * 200 / 1000}
    if variant == "b2":
        serial["entityDelta"] = {
            "bytesPerSync": bytes_per_sync, "firstSyncBytes": 5000, "bytesPerSyncBitpackedBound": bytes_per_sync * 0.6,
            "projectUsPerRoomSync": 3.0, "encodeOnlyUsPerRoomSync": 4.0, "encodeUsPerRoomSync": 7.0,
            "encodeSharedOnlyUsPerRoomSync": 1.0, "encodeSharedUsPerRoomSync": 4.0, "encoderStateBytes": 12000,
            "rssDeltaMiB": 1.5, "valueWriter": "byte-aligned"}
    return {"metadata": {"commandLine": cmd, "timestampUTC": "2026-11-08T00:00:00Z", "git": {"commit": "abc"},
                         "build": {"configuration": "release", "swiftVersion": "Swift version 6.2.4 (swift-6.2.4-RELEASE)"}},
            "results": [{"rooms": rooms, "playersPerRoom": players, "serial": serial}]}


def label(variant, rooms, players, cap, active):
    fmt = "entity-delta" if variant == "b2" else "messagepack-pathhash"
    return f"{fmt}-delta-r{rooms}-p{players}-m{cap or 0}{'-active' if active else ''}-serial"


def sweep(raw, run_id, repeat, scale=1.0, gate_ok=True, verified=True, skip=None, changed=None, captured=True, b1_skip=None):
    out = raw / run_id
    out.mkdir(parents=True)
    (out / "run.json").write_text(json.dumps({"runId": run_id, "repeat": repeat, "order": "sst-first", "nodeVersion": "v22",
                                              "superseded": None, "cells": []}))
    cells = [("rooms", dict(rooms=10, players=5)), ("monsters-cap50", dict(rooms=1, players=5, cap=50)),
             ("active-players", dict(rooms=1, players=10, cap=4, active=True))]
    for cell, kw in cells:
        for variant in FLAGS:
            if (cell, variant) == skip:
                continue
            base = {"sst-events": 700, "sst": 650, "b2": 330}[variant] * scale
            tag = f"{cell}-{variant}"
            (out / f"{tag}.json").write_text(json.dumps(benchmark(variant, bytes_per_sync=base, **kw)))
            name = label(variant, kw["rooms"], kw["players"], kw.get("cap"), kw.get("active", False))
            if not captured:
                continue
            room = {"comparisons": 10, "decodeErrors": 0, "differences": [] if gate_ok else [{"sync": 1}]}
            (out / f"{tag}.views.json").write_text(json.dumps({"runs": {name: [room]}}))
            decode = {"provenance": {"verified": verified},
                      "runs": {name: {"roomBytes": {"rooms": 1, "bytesPerRoomSync": base / kw["rooms"], "deflateBytesPerRoomSync": base / kw["rooms"] / 2},
                                      "summary": {"decodeApply": {"usPerFrame": 5.0},
                                                  "decode": None if variant == "b2" else {"usPerFrame": 1.0}}}}}
            (out / f"{tag}.decode.json").write_text(json.dumps(decode))
            key = "r" + name.split("-delta-r", 1)[1]
            state = "changed" if (cell, variant) == changed else "same"
            (out / f"{tag}.projections.json").write_text(json.dumps({key: {"room-0.ndjson": [state + cell]}}))
            if variant != "sst":
                continue
            for b1, typing in (("b1", "number"), ("b1-tuned", "tuned")):
                if (cell, b1) == b1_skip:
                    continue
                btag, bname = f"{cell}-{b1}", "colyseus-schema-delta-" + key
                per_room = (400 if b1 == "b1" else 380) * scale / kw["rooms"]
                (out / f"{btag}.colyseus.json").write_text(json.dumps({"package": "@colyseus/schema", "version": "5.0.42", "typing": typing,
                    "runs": {bname: {"rooms": 1, "syncs": 200, "firstSyncBytes": 900, "encodeUsPerRoomSyncNode": 9.0, "fieldTypes": {}}}}))
                (out / f"{btag}.views.json").write_text(json.dumps({"runs": {bname: [room]}}))
                (out / f"{btag}.decode.json").write_text(json.dumps({"provenance": {"verified": verified}, "runs": {bname: {
                    "roomBytes": {"rooms": 1, "bytesPerRoomSync": per_room, "deflateBytesPerRoomSync": per_room / 2},
                    "summary": {"decodeApply": {"usPerFrame": 7.0}, "decode": None}}}}))
                (out / f"{btag}.projections.json").write_text(json.dumps({key: {"room-0.ndjson": ["same" + cell]}}))


class Topic(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.raw, self.results = self.tmp / "raw", self.tmp / "results"

    def collect(self):
        return collect.collect(self.raw, self.results)

    def tables(self):
        runs = regenerate.load(self.results)
        regenerate.check(runs)
        return regenerate.tables(runs)

    def test_collects_each_cell_variant_and_repeat(self):
        sweep(self.raw, "a", 1)
        sweep(self.raw, "b", 2, scale=1.2)
        written = self.collect()
        self.assertEqual(len(written), 2 * 3 * 5)
        b1 = json.loads((self.results / "active-p10-r1-b1-tuned-rep1.json").read_text())
        self.assertEqual(b1["params"]["monster_cap"], 4)
        self.assertEqual(b1["metrics"]["bytes_per_room_sync_deflate"], 190)
        self.assertEqual(b1["meta"]["package"], "@colyseus/schema@5.0.42")
        self.assertIsNone(json.loads((self.results / "rooms-p5-r10-b1-rep1.json").read_text())["params"]["monster_cap"])
        r = json.loads((self.results / "monsters-p5-r1-cap50-b2-rep1.json").read_text())
        self.assertEqual(r["metrics"]["bytes_per_sync"], 330)
        self.assertEqual(r["metrics"]["bytes_per_sync_bitpacked_bound"], 198)
        self.assertTrue(r["metrics"]["gate_passed"])
        self.assertIsNone(r["metrics"]["decode_us_per_frame"])
        s = json.loads((self.results / "rooms-p5-r10-sst-rep2.json").read_text())
        self.assertAlmostEqual(s["metrics"]["sync_us_per_room_sync"], 2.0)
        self.assertAlmostEqual(s["metrics"]["bytes_per_sync"], 650 * 1.2)
        self.assertEqual(s["params"]["server_events"], False)
        self.assertEqual(json.loads((self.results / "rooms-p5-r10-sst-events-rep1.json").read_text())["params"]["server_events"], True)

    def test_tables_take_the_median_over_repeats(self):
        sweep(self.raw, "a", 1)
        sweep(self.raw, "b", 2, scale=1.2)
        sweep(self.raw, "c", 3, scale=2.0)
        self.collect()
        md = self.tables()
        self.assertIn("Medians over 3 repeat(s)", md)
        # rooms 10: SST events on 700/840/1400 → 840; SST 650/780/1300 → 780; B2 330/396/660 → 396.
        self.assertIn("| rooms 10 | 840 | 780 | 396 | 0.51 |", md)
        # Per room over the captured rooms: SST 78.0 / 39.0, B2 39.6 / 19.8, B1 48.0 / 24.0, B1 tuned 45.6 / 22.8.
        self.assertIn("| rooms 10 | 78.0 | 39.0 | 39.6 | 19.8 | 48.0 | 24.0 | 45.6 | 22.8 |", md)

    def test_refuses_a_failed_gate_an_unverified_decode_and_a_missing_variant(self):
        for kw, message in ((dict(gate_ok=False), "capture gate failed"), (dict(verified=False), "unverified"),
                            (dict(skip=("rooms", "sst")), "expected"),
                            (dict(changed=("monsters-cap50", "sst")), "projections differ"),
                            (dict(b1_skip=("rooms", "b1-tuned")), "expected")):
            with self.subTest(message):
                self.setUp()
                sweep(self.raw, "a", 1, **kw)
                self.collect()
                with self.assertRaises(SystemExit) as raised:
                    self.tables()
                self.assertIn(message, str(raised.exception))

    def test_refuses_flags_that_dont_match_the_variant(self):
        sweep(self.raw, "a", 1)
        path = self.raw / "a" / "rooms-sst.json"
        d = json.loads(path.read_text())
        d["metadata"]["commandLine"].remove("--no-server-events")
        path.write_text(json.dumps(d))
        with self.assertRaises(SystemExit):
            self.collect()

    def test_refuses_two_sweeps_claiming_one_repeat_unless_one_is_superseded(self):
        sweep(self.raw, "a", 1)
        sweep(self.raw, "b", 1)
        with self.assertRaises(SystemExit):
            self.collect()
        record = json.loads((self.raw / "a" / "run.json").read_text())
        record["superseded"] = {"reason": "redone"}
        (self.raw / "a" / "run.json").write_text(json.dumps(record))
        self.assertEqual(len(self.collect()), 15)

    def test_a_repeat_without_captures_needs_no_b1(self):
        sweep(self.raw, "a", 1)
        sweep(self.raw, "b", 2, captured=False)
        self.collect()
        self.assertIn("Medians over 2 repeat(s)", self.tables())

    def test_skips_a_sweep_of_only_some_cells(self):
        sweep(self.raw, "a", 1)
        record = json.loads((self.raw / "a" / "run.json").read_text())
        record["onlyCells"] = ["rooms"]
        (self.raw / "a" / "run.json").write_text(json.dumps(record))
        self.assertEqual(self.collect(), [])

    def test_dry_run_with_cells_runs_only_those(self):
        env = dict(os.environ, DRY_RUN="1", REPEAT="1", RUN_ID="dry", CELLS="monsters-cap4")
        out = subprocess.run(["bash", str(TOPIC / "run.sh")], env=env, capture_output=True, text=True, check=True).stdout
        measured = [l for l in out.splitlines() if "EncodingBenchmark --scalability" in l and "--capture-views" not in l]
        self.assertEqual(len(measured), 3)
        self.assertTrue(all("--monster-cap 4 " in l + " " for l in measured))
        bad = subprocess.run(["bash", str(TOPIC / "run.sh")], env=dict(env, CELLS="nope"), capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)

    def test_no_results_is_the_placeholder(self):
        self.assertEqual(self.tables(), regenerate.EMPTY)

    def test_dry_run_runs_three_variants_per_cell_with_their_flags(self):
        env = dict(os.environ, DRY_RUN="1", REPEAT="1", RUN_ID="dry")
        out = subprocess.run(["bash", str(TOPIC / "run.sh")], env=env, capture_output=True, text=True, check=True).stdout
        measured = [l for l in out.splitlines() if l.startswith("+ ") and "EncodingBenchmark --scalability" in l and "--capture-views" not in l]
        self.assertEqual(len(measured), 6 * 3)
        for line in measured:
            tag = line.split("> ")[1].split("/")[-1].split(".log")[0]
            variant = next(v for v in sorted(FLAGS, key=len, reverse=True) if tag.endswith("-" + v))
            self.assertEqual("--baseline entity-delta" in line, variant == "b2", line)
            self.assertEqual("--no-server-events" in line, variant != "sst-events", line)
            self.assertIn("--parallel false", line)
        lines = out.splitlines()
        self.assertEqual(sum("--capture-views" in l for l in lines), 6 * 3)
        # Every variant's capture, plus B1 (number and tuned) from each cell's sst capture.
        self.assertEqual(sum("time-decode-main.js" in l for l in lines), 6 * 5)
        self.assertEqual(sum("projhash.py" in l for l in lines), 6 * 5)
        converts = [l for l in lines if "colyseus-baseline-main.js" in l]
        self.assertEqual(len(converts), 6 * 2)
        self.assertTrue(all("/.views-" in l and "-sst " in l + " " for l in converts), converts[0])
        b2_first = subprocess.run(["bash", str(TOPIC / "run.sh")], env=dict(env, ORDER="b2-first"), capture_output=True, text=True, check=True).stdout
        first = next(l for l in b2_first.splitlines() if "EncodingBenchmark --scalability" in l)
        self.assertIn("--baseline entity-delta", first)


if __name__ == "__main__":
    unittest.main()
