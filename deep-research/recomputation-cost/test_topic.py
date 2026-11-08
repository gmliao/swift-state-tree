#!/usr/bin/env python3
"""Tests for run.sh, collect.py and regenerate.py on synthetic sweeps (no build needed).

Run: python3 test_topic.py
"""
import json
import os
import pathlib
import struct
import subprocess
import tempfile
import unittest

import collect
import regenerate

TOPIC = pathlib.Path(__file__).resolve().parent


def sstr(ticks=600, actions_per_tick=1, complete=True) -> bytes:
    log = regenerate.SSTR_MAGIC + bytes([3, 0])
    recs = [{"kind": "header", "metadata": {"rngSeed": 1, "landID": "hero-defense:room-0"}}]
    # Inputs alternate between client events (what ServerLoadTest sends) and actions.
    recs += [{"kind": "turn", "tickId": t, ("clientEvents" if t % 2 else "actions"): [{"a": t}] * actions_per_tick,
              "stateHash": f"h{t}"} for t in range(ticks)]
    if complete:
        recs.append({"kind": "footer", "complete": True})
    for rec in recs:
        body = regenerate.msgpack(rec)
        log += struct.pack(">I", len(body)) + body
    return log


def loadtest(rooms, players, cadence, record, enc="messagepack", cpu=40.0, actions=0, late=0, started="2026-11-08T00:00:00Z"):
    return {"metadata": {"timestampUTC": started, "commandLine": [".build/release/ServerLoadTest", "--rooms", str(rooms)],
                         "build": {"configuration": "release"},
                         "loadTestConfig": {"rooms": rooms, "playersPerRoom": players, "inputCadenceTicks": float(cadence),
                                            "record": record, "steadySeconds": 30, "tickIntervalMs": 50,
                                            "transportEncoding": {"message": enc}}},
            "results": {"stateUpdateFeatures": [] if enc == "json" else ["fieldMerge", "pathIndex"],
                        "joinFeatures": {"" if enc == "json" else "fieldMerge,pathIndex": rooms * players},
                        "summary": {"totalSeconds": 40, "steadySeconds": 30, "totalActionsCompleted": actions,
                                    "process": {"steadyCPUPercentMean": cpu},
                                    "pacing": {"lateSeconds": late, "skippedByCap": 0}},
                        # 5 ramp-up, 30 steady and 5 ramp-down seconds; only the steady ones count.
                        "seconds": [{"t": t, "phase": "ramp-up" if t < 5 else "steady" if t < 35 else "ramp-down",
                                     "actionsCompletedThisSecond": 10 if 5 <= t < 35 else 99} for t in range(40)]}}


PROFILE = "\n".join(json.dumps({"lag_ms": float(i), "encode_ms": {"p99_ms": 1.0}, "send_ms": {"p99_ms": 2.0},
                                "sync_extract_ms": {"sum": 3.0, "plans": 3}}) for i in range(10)) + "\n"


def sweep(raw, run_id="s1", dirty=False, swift="Swift version 6.2.4 (swift-6.2.4-RELEASE)", skip=None,
          check_ok=True, late=0, swap_order=False, noise=True, constants=None, cells=None):
    out = raw / run_id
    out.mkdir(parents=True)
    record = {"runId": run_id, "pinCpus": "0-7", "onlyCells": cells, **regenerate.CONSTANTS, **(constants or {}),
              "git": {"commit": "abc", "dirty": dirty}, "swiftVersion": swift, "endedAt": "2026-11-08T01:00:00Z"}
    (out / "run.json").write_text(json.dumps(record))
    procs = []
    for players, cadence in regenerate.CELLS:
        for enc in ("messagepack", "json"):
            procs.append((f"sizes-{enc}-p{players}-c{cadence}-r1", "sizes", players, cadence, "on", enc))
        for rep, order in regenerate.COST_ORDERS.items():
            sides = tuple(reversed(order)) if swap_order and rep == 1 else order
            for i, side in enumerate(sides):
                procs.append((f"cost-p{players}-c{cadence}-r{rep}-{side}", "cost", players, cadence, side, f"T{rep}{i}"))
    procs.append(("sizes-messagepack-p10-c5-r2", "sizes", 10, 5, "on", "messagepack"))
    if noise:
        procs += [("noise-p10-c5-a", "noise", 10, 5, "off", "Ta"), ("noise-p10-c5-b", "noise", 10, 5, "off", "Tb")]
    for name, kind, players, cadence, side, extra in procs:
        if name == skip:
            continue
        d = out / name
        d.mkdir()
        if kind == "sizes":
            (d / "loadtest.json").write_text(json.dumps(loadtest(10, players, cadence, "on", enc=extra)))
            (d / "records").mkdir()
            for room in (0, 1):
                (d / "records" / f"room-{room}.sstr").write_bytes(sstr(ticks=20))
            (d / "streams").mkdir()
            (d / "streams" / "s0.bin").write_bytes(struct.pack(">I", 2) + b"ab")
            if extra == "messagepack" and name.endswith("-r1"):
                for room in (0, 1):
                    (d / f"replay-room-{room}.txt").write_text("REPLAY_TIMING run=1 ticks=20 wallMs=2.0\n")
                    (d / f"verify-room-{room}.txt").write_text(
                        "Verified state hashes\nREPLAY_TIMING run=1 ticks=20 wallMs=2.0\nREPLAY_TIMING run=2 ticks=20 wallMs=2.0\n")
                    (d / f"open-room-{room}.json").write_text(json.dumps(
                        {"medianMs": 0.5, "p10Ms": 0.4, "p90Ms": 0.6, "repeat": 200, "bytes": 100}) + "\n")
        else:
            cpu = 50.0 if side == "on" else 40.0
            (d / "loadtest.json").write_text(json.dumps(loadtest(200, players, cadence, "on" if side == "on" else "off",
                                                                 cpu=cpu, late=late, started=f"2026-11-08T00:{extra}")))
            (d / "profile.jsonl").write_text(PROFILE)
            if side == "on":
                (d / "record-check.json").write_text(json.dumps({"pass": check_ok}))


class RecordCheckTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.d = pathlib.Path(tmp.name)
        (self.d / "records").mkdir()
        (self.d / "verify.txt").write_text("Verified state hashes\n")

    def write(self, rooms=2, actions=1200, **record_kw):
        (self.d / "loadtest.json").write_text(json.dumps(loadtest(rooms, 2, 5, "on", actions=actions)))
        for room in range(2):
            (self.d / "records" / f"room-{room}.sstr").write_bytes(sstr(**record_kw))

    def test_complete_records_pass(self):
        self.write()  # 2 records × 600 ticks × 1 action
        self.assertTrue(regenerate.record_check(self.d)["pass"])

    def test_each_shortfall_fails(self):
        for kw, field in ((dict(rooms=3), "records"), (dict(actions=1199), "recordedActions"),
                          (dict(complete=False), "incomplete"), (dict(ticks=599, actions=1198), "minTicks")):
            with self.subTest(field):
                self.write(**kw)
                self.assertFalse(regenerate.record_check(self.d)["pass"], field)

    def test_spool_left_or_unverified_fails(self):
        self.write()
        (self.d / "records" / "spool").mkdir()
        (self.d / "records" / "spool" / "room-2.part").write_bytes(b"x")
        self.assertFalse(regenerate.record_check(self.d)["pass"])
        (self.d / "records" / "spool" / "room-2.part").unlink()
        (self.d / "verify.txt").write_text("state hash mismatch at tick 3\n")
        self.assertFalse(regenerate.record_check(self.d)["pass"])


class TopicTests(unittest.TestCase):
    def collect(self, **kw):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        raw, results = pathlib.Path(tmp.name) / "raw", pathlib.Path(tmp.name) / "results"
        sweep(raw, **kw)
        collect.collect(raw, results)
        return regenerate.load(results)

    def refused(self, runs, text):
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs)
        self.assertIn(text, str(cm.exception))

    def test_collect_and_tables(self):
        runs = self.collect()
        self.assertEqual(len(runs), 6 * (2 + 8) + 1 + 2)
        regenerate.check(runs)
        md = regenerate.results_markdown(runs)
        # CPU 50 / 40: +10 points; core-ms per room-tick 10 × 10 / (200 × 20) = 0.025.
        # 10 actions per steady second; the ramp seconds' 99 are left out.
        self.assertIn("| 2 | 5 | 10.0 / 10.0 | 50.0 / 40.0 | +10.0 | +0.0250 | 1.250 [1.250–1.250] |", md)
        self.assertIn("| 2 | 5 | room-0 | 20 | 2.0 | 100.0 | 500 | 0.500 |", md)
        self.assertIn("| messagepack | 10 | 5 | 2 |", md)
        self.assertIn("Noise floor: two recording-off processes at 10 players, cadence 5: CPU 40.0 % and 40.0 %", md)

    def test_refuses_provenance(self):
        self.refused(self.collect(dirty=True), "not from a clean tree")
        self.refused(self.collect(swift="Swift version 6.3.2"), "not the pinned 6.2.4")

    def test_refuses_saturation_a_failed_record_check_and_the_order(self):
        self.refused(self.collect(late=1), "saturated (late seconds 1")
        self.refused(self.collect(check_ok=False), "the record check failed")
        self.refused(self.collect(swap_order=True), "rep1: ran off-on, the ABBA order has on-off")

    def test_refuses_a_run_off_its_wire_form(self):
        runs = self.collect()
        def refused_with(mutate, text):
            changed = json.loads(json.dumps(runs))
            mutate(next(r for r in changed if r["params"]["kind"] == "cost"))
            self.refused(changed, text)
        refused_with(lambda r: r["wire"].update(stateUpdateFeatures=["fieldMerge"]),
                     "messagepack, pathIndex off, fieldMerge on, intended messagepack, pathIndex on, fieldMerge on")
        refused_with(lambda r: r["wire"].update(stateUpdateFeatures=None, joinFeatures={"": 1, "pathIndex": 3}),
                     "wire form missing: the joins agreed on no stateUpdateFeatures")
        # Not recorded, and the sweep's commit isn't one this repository knows: missing, not off.
        refused_with(lambda r: r["wire"].update(recorded=False, stateUpdateFeatures=None), "wire form missing: pathIndex not recorded")

    def test_refuses_missing_processes(self):
        self.refused(self.collect(skip="cost-p5-c20-r3-off"), "p5-c20 rep3: cost sides ['on']")
        self.refused(self.collect(skip="sizes-json-p2-c5-r1"), "p2-c5: no json sizes run")
        self.refused(self.collect(skip="sizes-messagepack-p10-c5-r2"), "no second sizes repeat")
        self.refused(self.collect(noise=False), "0 noise runs")

    def test_collect_skips_smoke_sweeps(self):
        self.assertEqual(self.collect(cells=["p2-c5"]), [])
        self.assertEqual(self.collect(constants={"costRooms": 4}), [])


class RunScriptTests(unittest.TestCase):
    def dry(self, **env):
        done = subprocess.run(["bash", str(TOPIC / "run.sh")], capture_output=True, text=True,
                              env={**os.environ, "DRY_RUN": "1", "RUN_ID": "dry", **env})
        return done.returncode, done.stdout + done.stderr

    def test_dry_run_lists_every_process(self):
        code, out = self.dry()
        self.assertEqual(code, 0, out)
        runs = [l for l in out.splitlines() if "ServerLoadTest --rooms" in l]
        self.assertEqual(len(runs), 12 + 1 + 6 * 8 + 2)
        self.assertEqual(sum("--stream-dir" in l for l in runs), 13)
        self.assertFalse(any("--stream-dir" in l for l in runs if "--rooms 200" in l), "cost runs must not dump streams")
        on = [l for l in runs if "--rooms 200" in l and "--record on" in l]
        self.assertEqual(len(on), 24)
        self.assertTrue(all("--record-dir" in l and "TRANSPORT_PROFILE_JSONL_PATH" in l for l in on))
        self.assertEqual(sum("--record-check" in l for l in out.splitlines()), 24)
        self.assertEqual(sum("--time-open" in l for l in out.splitlines()), 12)
        # ABBA: repeat 1 runs on first, repeat 2 off first.
        r1 = [l for l in runs if "/cost-p2-c5-r1-" in l]
        r2 = [l for l in runs if "/cost-p2-c5-r2-" in l]
        self.assertIn("--record on", r1[0])
        self.assertIn("--record off", r2[0])

    def test_refusals(self):
        self.assertEqual(self.dry(CELLS="p3-c5")[0], 2)
        self.assertEqual(self.dry(SIZE_ROOMS="1")[0], 2)
        self.assertEqual(self.dry(COST_REPEATS="5")[0], 2)
        self.assertEqual(self.dry(RUN_ID="a/b")[0], 2)


if __name__ == "__main__":
    unittest.main()
