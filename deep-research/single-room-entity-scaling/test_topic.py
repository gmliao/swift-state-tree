#!/usr/bin/env python3
"""Tests for collect.py and regenerate.py on synthetic sweeps, and run.sh's dry run.

Usage: python3 test_topic.py
"""
import json, os, pathlib, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import collect, regenerate  # noqa: E402
import serverenv  # noqa: E402  (on the path through regenerate)

# The fixture's cells: one idle point and one active list of two.
FIXTURE_POINTS = {"monsters-cap4": [(5, 4, "idle")], "active-players": [(5, 4, "active"), (10, 4, "active")]}
COMMIT = "1d372f39"  # contains both knobs
BYTES = {"json": 3000, "off-off": 1000, "on-off": 900, "off-on": 800, "on-on": 700}


def benchmark(cell, form, players, cap, active, scale=1):
    fmt, path_index, field_merge = regenerate.FORMS[form]
    cmd = ["EncodingBenchmark", "--scalability", "--format", fmt, "--room-counts", "1", "--iterations", "200",
           "--ticks-per-sync", "2", "--parallel", "false", "--players-per-room-list", ",".join(map(str, players)),
           "--monster-cap", str(cap)] + (["--active-players"] if active else [])
    return {"metadata": {"commandLine": cmd, "timestampUTC": "2026-11-08T00:00:00Z", "git": {"commit": COMMIT},
                         "pathIndex": path_index, "fieldMerge": field_merge, "dynamicKeyCompression": True,
                         "dirtyTracking": "on",
                         "build": {"configuration": "release", "swiftVersion": "Swift version 6.2.4 (swift-6.2.4-RELEASE)"}},
            "results": [{"rooms": 1, "playersPerRoom": p, "config": {"mode": "serial"},
                         "serial": {"totalBytes": BYTES[form] * p * 200 * scale, "finalMonsterCount": cap}} for p in players]}


def views(players, cap, active, ok=True):
    return {"runs": {f"x-r1-p{p}-m{cap}{'-active' if active else ''}-serial":
                     [{"decodeErrors": 0, "differences": [] if ok else ["x"], "comparisons": 10}] for p in players}}


def sweep(raw, run_id, repeat, *, gate_ok=True, only=None, env=None, skip=(), override=None):
    d = raw / run_id
    d.mkdir(parents=True)
    (d / "run.json").write_text(json.dumps({
        "runId": run_id, "repeat": repeat, "capture": True, "pinCpus": "0-7", "onlyCells": only,
        "serverEnv": env if env is not None else serverenv.record({}),
        "git": {"commit": COMMIT, "dirty": False}, "superseded": None, "cells": []}))
    for cell, players, cap, active in (("monsters-cap4", [5], 4, False), ("active-players", [5, 10], 4, True)):
        for form in regenerate.FORMS:
            if (cell, form) in skip:
                continue
            b = benchmark(cell, form, players, cap, active)
            if override:
                override(cell, form, b)
            (d / f"{cell}-{form}.json").write_text(json.dumps(b))
            (d / f"{cell}-{form}.views.json").write_text(json.dumps(views(players, cap, active, gate_ok)))


class Topic(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.raw, self.results = pathlib.Path(tmp.name) / "raw", pathlib.Path(tmp.name) / "results"

    def runs(self, *sweeps_kw):
        for i, kw in enumerate(sweeps_kw, 1):
            sweep(self.raw, f"s{i}", i, **kw)
        collect.collect(self.raw, self.results)
        return regenerate.load(self.results)

    def refused(self, runs, text):
        with self.assertRaises(SystemExit) as raised:
            regenerate.check(runs, points=FIXTURE_POINTS)
        self.assertIn(text, str(raised.exception))

    def test_collect_check_and_tables(self):
        runs = self.runs({}, {})
        self.assertEqual(len(runs), 2 * 3 * 5)
        regenerate.check(runs, points=FIXTURE_POINTS)
        r = next(r for r in runs if r["params"]["cell"] == "active-players" and r["params"]["players"] == 10
                 and r["params"]["form"] == "off-on" and r["params"]["repeat"] == 2)
        self.assertEqual(r["metrics"]["bytes_per_sync"], 8000.0)
        self.assertEqual(r["metrics"]["bytes_per_player_per_sync"], 800.0)
        self.assertTrue(r["metrics"]["gate_passed"])
        md = regenerate.tables(runs)
        self.assertIn("| 10 | 4 | 30,000 | 10,000 | 9,000 | 8,000 | 7,000 | 30.0% | 10.0% | 20.0% |", md)
        self.assertIn("### Monster axis", md)

    def test_skips_a_smoke_sweep(self):
        self.assertEqual(self.runs({"only": "monsters-cap4 forms:on-on"}), [])

    def test_refuses_a_run_whose_recorded_form_isnt_its_label(self):
        def swap(cell, form, b):
            if cell == "monsters-cap4" and form == "on-off":
                b["metadata"]["fieldMerge"] = True
        self.refused(self.runs({"override": swap}, {}),
                     "monsters-cap4 p5 on-off rep1: ran messagepack-pathhash, pathIndex on, fieldMerge on, its label says messagepack-pathhash, pathIndex on, fieldMerge off")

    def test_refuses_off_off_bytes_equal_to_on_on(self):
        def same(cell, form, b):
            if form == "off-off" and cell == "monsters-cap4":
                for r in b["results"]:
                    r["serial"]["totalBytes"] = BYTES["on-on"] * r["playersPerRoom"] * 200
        self.refused(self.runs({"override": same}, {"override": same}), "monsters-cap4 p5: off-off bytes equal on-on bytes: the knobs")

    def test_refuses_a_single_knob_that_doesnt_change_the_bytes(self):
        for form, knob in (("off-on", "the path index"), ("on-off", "the field merge")):
            def same(cell, f, b, form=form):
                if f == form and cell == "active-players":
                    for r in b["results"]:
                        r["serial"]["totalBytes"] = BYTES["on-on"] * r["playersPerRoom"] * 200
            with self.subTest(form):
                self.setUp()
                self.refused(self.runs({"override": same}, {"override": same}),
                             f"active-players p5: {form} bytes equal on-on bytes: {knob} didn't reach the encoder")

    def test_refuses_bytes_that_differ_between_repeats(self):
        def more(cell, form, b):
            if cell == "joint" or (cell, form) != ("monsters-cap4", "json"):
                return
            b["results"][0]["serial"]["totalBytes"] += 1
        self.refused(self.runs({}, {"override": more}), "monsters-cap4 p5 json: bytes differ between repeats")

    def test_refuses_a_missing_form_or_repeat_and_a_failed_gate(self):
        self.refused(self.runs({}, {"skip": [("active-players", "off-on")]}), "active-players p5 off-on: 0 results for repeat 2")
        self.setUp()
        self.refused(self.runs({}, {"gate_ok": False}), "the verify-views gate failed")

    def test_refuses_a_server_environment_or_a_parameter_off_the_shipped_path(self):
        self.refused(self.runs({"env": serverenv.record({"USE_SNAPSHOT_FOR_SYNC": "false"})}, {}), "server environment set")
        self.setUp()
        self.refused(self.runs({"env": serverenv.record({"HERO_DEFENSE_SERVER_EVENTS": "false"})}, {}), "server environment set")
        self.setUp()
        self.refused(self.runs({"env": {"USE_SNAPSHOT_FOR_SYNC": None}}, {}), "server environment lacks")
        self.setUp()
        def strategy(cell, form, b):
            b["metadata"]["commandLine"] += ["--sync-strategy", "full-snapshot"]
        self.refused(self.runs({"override": strategy}, {}), "sync_strategy 'full-snapshot', the matrix has 'delta'")
        self.setUp()
        def parallel(cell, form, b):
            for r in b["results"]:
                r["config"]["mode"] = "parallel"
        self.refused(self.runs({"override": parallel}, {}), "parallel True, the matrix has False")

    def test_the_record_must_be_both_knobs_off(self):
        old = {"meta": {"git_sha": "9f65c9e", "source_file": "a.json"}, "params": {"encoding": "messagepack-pathhash"}}
        regenerate.check_record([old])
        new = {"meta": {"git_sha": COMMIT, "source_file": "b.json"}, "params": {"encoding": "messagepack-pathhash"}}
        with self.assertRaises(SystemExit) as raised:
            regenerate.check_record([new])
        self.assertIn("b.json: wire form missing", str(raised.exception))
        on = {"meta": {"git_sha": COMMIT, "path_index": True, "field_merge": False, "source_file": "c.json"},
              "params": {"encoding": "messagepack-pathhash"}}
        with self.assertRaises(SystemExit) as raised:
            regenerate.check_record([on])
        self.assertIn("c.json: messagepack-pathhash, pathIndex on, fieldMerge off, the record is both knobs off", str(raised.exception))

    def test_run_sh_and_runmeta_take_the_shared_list(self):
        # One list (deep-research/serverenv.py): run.sh unsets what runmeta.py records.
        env = dict(os.environ, DRY_RUN="1", REPEAT="1", RUN_ID="dry")
        out = subprocess.run(["bash", str(TOPIC / "run.sh")], env=env, capture_output=True, text=True, check=True).stdout
        self.assertIn("+ unset " + " ".join(serverenv.SERVER_ENV) + "\n", out)
        self.assertNotIn("SERVER_ENV", (TOPIC / "runmeta.py").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([sys.executable, str(TOPIC / "runmeta.py"), "start", tmp, "r", "1", "1", "0-7", "0"],
                           env={**os.environ, "IN_TURN_SYNC": "true"}, check=True, capture_output=True)
            record = json.loads((pathlib.Path(tmp) / "run.json").read_text())
        self.assertEqual(record["serverEnv"], {**serverenv.record({}), "IN_TURN_SYNC": "true"})

    def test_the_matrix_is_run_shs(self):
        env = dict(os.environ, DRY_RUN="1", REPEAT="1", RUN_ID="dry")
        out = subprocess.run(["bash", str(TOPIC / "run.sh")], env=env, capture_output=True, text=True, check=True).stdout
        cmds = [l for l in out.splitlines() if "EncodingBenchmark --scalability" in l and "--capture-views" not in l]
        self.assertEqual(len(cmds), len(regenerate.POINTS) * len(regenerate.FORMS))
        seen = {}
        for line in cmds:
            args = line.split()
            players = [int(p) for p in args[args.index("--players-per-room-list") + 1].split(",")]
            cap = int(args[args.index("--monster-cap") + 1])
            workload = "active" if "--active-players" in args else "idle"
            tag = pathlib.Path(line.split("> ")[1].split()[0]).stem
            cell, form = collect.split_tag(tag)
            seen.setdefault(cell, set()).update((p, cap, workload) for p in players)
            fmt = args[args.index("--format") + 1]
            pi = args[args.index("--path-index") + 1] == "on" if "--path-index" in args else True
            fm = args[args.index("--field-merge") + 1] == "on" if "--field-merge" in args else True
            self.assertEqual((fmt, pi, fm), regenerate.FORMS[form], line)
            for flag, want in (("--room-counts", "1"), ("--iterations", "200"), ("--ticks-per-sync", "2"), ("--parallel", "false")):
                self.assertEqual(args[args.index(flag) + 1], want, line)
            self.assertNotIn("--sync-strategy", args)
        self.assertEqual({c: sorted(v) for c, v in seen.items()}, {c: sorted(v) for c, v in regenerate.POINTS.items()})


if __name__ == "__main__":
    unittest.main()
