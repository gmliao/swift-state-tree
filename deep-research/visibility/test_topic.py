#!/usr/bin/env python3
"""Tests for run.sh (dry run), capcheck.py, collect.py and regenerate.py, with no build: synthetic
captures and a synthetic sweep in a temporary directory.

Usage: python3 test_topic.py
"""
import copy, json, os, pathlib, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import capcheck, collect, regenerate  # noqa: E402
import serverenv  # noqa: E402  (on the path through regenerate)


def pos(x, y):
    return {"v": {"x": x, "y": y}}


def projection(viewers, entities, tick=1):
    return {"entities": entities, "motion": True, "tickCount": tick, "viewEntries": 3, "viewExits": 1, "viewers": viewers}


def write_capture(root, filter_, radius, checkpoints, players=("p0",), tps=1):
    """One run, one room: checkpoints is a list of {player: projection}."""
    run = root / "messagepack-pathhash-delta-visibility-test-r1-p1-k1-serial"
    run.mkdir(parents=True)
    header = {"cell": {"visibility": {"entityCount": 2, "filter": filter_, "viewRadius": radius}, "ticksPerSync": tps},
              "sessions": {f"s-{p}": p for p in players}}
    lines = [json.dumps(header)] + [json.dumps({"frames": [], "projections": c, "sync": i}) for i, c in enumerate(checkpoints)]
    (run / "room-0.ndjson").write_text("\n".join(lines) + "\n")
    return root


class CapcheckTests(unittest.TestCase):
    def test_quantize_matches_fixed_point(self):
        self.assertEqual(capcheck.quantize(15), 15000)
        self.assertEqual(capcheck.quantize(8.5), 8500)
        self.assertEqual(capcheck.quantize(0.0015), 2)
        self.assertEqual(capcheck.quantize(-0.0015), -2)

    def test_radius_is_inclusive_and_one_quantum_past_is_out(self):
        viewer = pos(20000, 20000)
        self.assertTrue(capcheck.admits(viewer, pos(35000, 20000), 15000))
        self.assertFalse(capcheck.admits(viewer, pos(35001, 20000), 15000))
        self.assertTrue(capcheck.admits(viewer, pos(20000 + 9000, 20000 + 12000), 15000))

    def consistency(self, radius_entities, all_entities):
        viewers = {"p0": {"position": pos(20000, 20000), "slot": 0}}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            r = write_capture(tmp / "r", "radius", 15.0, [{"p0": projection(viewers, radius_entities)}])
            a = write_capture(tmp / "a", "all", 15.0, [{"p0": projection(viewers, all_entities)}])
            try:
                capcheck.consistency(r, a, tmp / "out.json")
                ok = True
            except SystemExit:
                ok = False
            return ok, json.loads((tmp / "out.json").read_text())

    def test_consistent_pair_passes(self):
        inside = {"id": "e0", "position": pos(35000, 20000)}
        outside = {"id": "e1", "position": pos(35001, 20000)}
        ok, report = self.consistency({"e0": inside}, {"e0": inside, "e1": outside})
        self.assertTrue(ok)
        self.assertEqual(report["r1-p1-k1-serial"]["checks"], 1)

    def test_leaked_entity_fails(self):
        inside = {"id": "e0", "position": pos(35000, 20000)}
        outside = {"id": "e1", "position": pos(35001, 20000)}
        ok, report = self.consistency({"e0": inside, "e1": outside}, {"e0": inside, "e1": outside})
        self.assertFalse(ok)
        self.assertIn("extra ['e1']", report["r1-p1-k1-serial"]["failure"])

    def test_missing_entity_fails(self):
        inside = {"id": "e0", "position": pos(35000, 20000)}
        ok, report = self.consistency({}, {"e0": inside})
        self.assertFalse(ok)
        self.assertIn("missing ['e0']", report["r1-p1-k1-serial"]["failure"])

    def test_differing_positions_fail(self):
        ok, report = self.consistency({"e0": {"id": "e0", "position": pos(30000, 20000)}},
                                      {"e0": {"id": "e0", "position": pos(30001, 20000)}})
        self.assertFalse(ok)
        self.assertIn("entity e0 differs", report["r1-p1-k1-serial"]["failure"])

    def test_differing_broadcast_fails(self):
        viewers = {"p0": {"position": pos(20000, 20000), "slot": 0}}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            r = write_capture(tmp / "r", "radius", 15.0, [{"p0": projection(viewers, {}, tick=1)}])
            a = write_capture(tmp / "a", "all", 15.0, [{"p0": projection(viewers, {}, tick=2)}])
            with self.assertRaises(SystemExit):
                capcheck.consistency(r, a, tmp / "out.json")

    def broadcast_consistency(self, broadcast_views, all_views, filters=("broadcast", "all")):
        """One checkpoint, players p0 and p1: each argument maps a player to its projection."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            b = write_capture(tmp / "b", filters[0], 15.0, [broadcast_views], players=("p0", "p1"))
            a = write_capture(tmp / "a", filters[1], 15.0, [all_views], players=("p0", "p1"))
            try:
                capcheck.consistency(b, a, tmp / "out.json", capcheck.compare_broadcast_room)
                ok = True
            except SystemExit:
                ok = False
            return ok, json.loads((tmp / "out.json").read_text())["r1-p1-k1-serial"]

    def test_broadcast_twin_equal_to_every_all_view_passes(self):
        viewers = {"p0": {"position": pos(20000, 20000), "slot": 0}, "p1": {"position": pos(80000, 20000), "slot": 1}}
        view = projection(viewers, {"e0": {"id": "e0", "position": pos(1, 2)}})
        ok, report = self.broadcast_consistency({"p0": view, "p1": view}, {"p0": view, "p1": copy.deepcopy(view)})
        self.assertTrue(ok)
        self.assertEqual(report["checks"], 2)

    def test_broadcast_twin_differing_from_one_players_all_view_fails(self):
        viewers = {"p0": {"position": pos(20000, 20000), "slot": 0}, "p1": {"position": pos(80000, 20000), "slot": 1}}
        view = projection(viewers, {"e0": {"id": "e0", "position": pos(1, 2)}})
        moved = projection(viewers, {"e0": {"id": "e0", "position": pos(1, 3)}})
        ok, report = self.broadcast_consistency({"p0": view, "p1": view}, {"p0": view, "p1": moved})
        self.assertFalse(ok)
        self.assertIn("p1: view differs in ['entities']", report["failure"])
        ok, report = self.broadcast_consistency({"p0": view, "p1": view}, {"p0": view, "p1": dict(view, viewExits=2)})
        self.assertIn("p1: view differs in ['viewExits']", report["failure"])

    def test_broadcast_consistency_refuses_other_filters(self):
        view = projection({}, {})
        ok, report = self.broadcast_consistency({"p0": view, "p1": view}, {"p0": view, "p1": view}, filters=("radius", "all"))
        self.assertFalse(ok)
        self.assertIn("expected broadcast/all", report["failure"])

    def stats(self, checkpoints, tps=1, filter_="radius"):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            cap = write_capture(tmp / "c", filter_, 15.0, checkpoints, players=("p0", "p1"), tps=tps)
            capcheck.stats(cap, tmp / "s.json")
            return json.loads((tmp / "s.json").read_text())["r1-p1-k1-serial"]

    def two_viewers(self, entries, exits, p0, p1):
        """Checkpoint 0 (p0 sees e0, p1 nothing, counters 0) then one measured sync."""
        viewers = {"p0": {"position": pos(0, 0), "slot": 0}, "p1": {"position": pos(0, 0), "slot": 1}}
        def at(entities, entries_, exits_):
            return dict(projection(viewers, {e: {} for e in entities}), viewEntries=entries_, viewExits=exits_)
        return [{"p0": at(["e0"], 0, 0), "p1": at([], 0, 0)},
                {"p0": at(p0, entries, exits), "p1": at(p1, entries, exits)}]

    def test_stats_counts_the_room_counters_once(self):
        # p0: e0 leaves, e1 enters (2); p1: e1 enters (1). The room counters grow by 3 in all.
        s = self.stats(self.two_viewers(2, 1, ["e1"], ["e1"]))
        self.assertEqual(s["visiblePerRecipient"], 1)
        self.assertEqual(s["viewChangesPerRecipientSync"], 1.5)
        self.assertEqual(s["observedViewChangesPerRecipientSync"], 1.5)

    def test_stats_refuses_counters_that_disagree_with_the_projections(self):
        with self.assertRaises(SystemExit):
            self.stats(self.two_viewers(1, 1, ["e1"], ["e1"]))
        # With two ticks per sync a transition undone within the sync is invisible: fewer is fine.
        s = self.stats(self.two_viewers(3, 2, ["e1"], ["e1"]), tps=2)
        self.assertEqual(s["viewChangesPerRecipientSync"], 2.5)
        with self.assertRaises(SystemExit):
            self.stats(self.two_viewers(1, 1, ["e1"], ["e1"]), tps=2)

    def test_stats_all_control(self):
        viewers = {"p0": {"position": pos(0, 0), "slot": 0}, "p1": {"position": pos(0, 0), "slot": 1}}
        def at(entries):
            return {p: dict(projection(viewers, {"e0": {}, "e1": {}}), viewEntries=entries, viewExits=0) for p in ("p0", "p1")}
        s = self.stats([at(0), at(3)], filter_="all")
        self.assertEqual(s["visiblePerRecipient"], 2)
        self.assertEqual(s["viewChangesPerRecipientSync"], 1.5)
        missing = [at(0), at(3)]
        missing[1]["p1"] = dict(missing[1]["p1"], entities={"e0": {}})
        with self.assertRaises(SystemExit):
            self.stats(missing, filter_="all")

    def test_stats_refuses_per_player_counters(self):
        checkpoints = self.two_viewers(2, 1, ["e1"], ["e1"])
        checkpoints[1]["p1"]["viewEntries"] = 1
        with self.assertRaises(SystemExit):
            self.stats(checkpoints)


def benchmark(cell, variant, rooms=10, iterations=200):
    entities, radius, players, tps = regenerate.CELLS[cell]
    cmd = [".build/release/EncodingBenchmark", "--scalability", "--game-type", "visibility-test", "--format", "messagepack-pathhash",
           "--sync-strategy", "delta", "--iterations", str(iterations), "--ticks-per-sync", str(tps), "--parallel", "false",
           "--no-server-events", "--players-per-room-list", str(players), "--room-counts", str(rooms)]
    bytes_per_recipient = {"radius": 40.0, "all": 100.0, "broadcast": 99.0}[variant]
    sync_ms = {"radius": 0.01, "all": 0.01, "broadcast": 0.004}[variant]
    serial = {"totalBytes": bytes_per_recipient * iterations * rooms * players, "syncMs": sync_ms * rooms * iterations,
              "tickMs": 0.02 * rooms * iterations * tps}
    settings = {"VISIBILITY_TEST_ENTITY_COUNT": str(entities), "VISIBILITY_TEST_VIEW_RADIUS": f"{radius:.1f}",
                "VISIBILITY_TEST_FILTER": variant}
    return {"metadata": {"commandLine": cmd, "timestampUTC": "2026-11-08T00:00:00Z", "git": {"commit": "abc"},
                         "pathIndex": True, "fieldMerge": True,
                         "build": {"configuration": "release", "swiftVersion": "Swift version 6.2.4 (swift-6.2.4-RELEASE)"},
                         "benchmarkConfig": {"gameType": "visibility-test", "iterations": iterations, "ticksPerSync": tps,
                                             "visibility": settings}},
            "results": [{"rooms": rooms, "playersPerRoom": players, "serial": serial}]}


def sweep(raw, run_id, repeat, captured=True, gate_ok=True, replay_ok=True, consistent=True, broadcast_consistent=True,
          skip=None, dirty=False, order=None):
    out = raw / run_id
    out.mkdir(parents=True)
    (out / "run.json").write_text(json.dumps({"runId": run_id, "repeat": repeat, "order": order or regenerate.ORDERS[(repeat - 1) % 3], "nodeVersion": "v22",
                                              "git": {"commit": "abc", "dirty": dirty}, "superseded": None, "cells": [],
                                              "serverEnv": serverenv.record({})}))
    for cell in ("default", "tps2"):
        entities, radius, players, tps = regenerate.CELLS[cell]
        key = f"r10-p{players}-k{tps}-serial"
        name = f"messagepack-pathhash-delta-visibility-test-{key}"
        for variant in regenerate.VARIANTS:
            if (cell, variant) == skip:
                continue
            tag = f"{cell}-{variant}"
            (out / f"{tag}.json").write_text(json.dumps(benchmark(cell, variant)))
            if not captured:
                continue
            room = {"comparisons": 10, "decodeErrors": 0, "differences": [] if gate_ok else [{"sync": 1}]}
            (out / f"{tag}.views.json").write_text(json.dumps({"runs": {name: [room, room]}}))
            (out / f"{tag}.decode.json").write_text(json.dumps({"provenance": {"verified": True}, "runs": {name: {
                "roomBytes": {"rooms": 2, "bytesPerRoomSync": 160.0 * players, "deflateBytesPerRoomSync": 80.0 * players},
                "summary": {"decode": {"usPerFrame": 1.0}, "decodeApply": {"usPerFrame": 5.0}}}}}))
            (out / f"{tag}.capstats.json").write_text(json.dumps({key: {"rooms": 2, "visiblePerRecipient": 3.0, "viewChangesPerRecipientSync": 0.5}}))
            (out / f"{tag}.replay.json").write_text(json.dumps({key: {"room-0.sstr": {"passed": replay_ok}, "room-1.sstr": {"passed": True}}}))
        if captured:
            (out / f"{cell}.consistency.json").write_text(json.dumps({key: {"rooms": 2, "checks": 84, "failure": None if consistent else "x"}}))
            (out / f"{cell}.broadcast-consistency.json").write_text(
                json.dumps({key: {"rooms": 2, "checks": 85, "failure": None if broadcast_consistent else "x"}}))


class TopicTests(unittest.TestCase):
    def collect(self, *sweeps_kw):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        raw, results = pathlib.Path(tmp.name) / "raw", pathlib.Path(tmp.name) / "results"
        for i, kw in enumerate(sweeps_kw, 1):
            sweep(raw, f"s{i}", i, **kw)
        collect.collect(raw, results)
        return regenerate.load(results)

    def test_refuses_a_run_off_the_wire_form_or_without_one(self):
        runs = self.collect({}, {"captured": False}, {"captured": False})
        runs[0]["meta"].update(path_index=True, field_merge=False)
        runs[1]["meta"].update(path_index=None, field_merge=None)  # commit "abc" is unknown: missing, not off
        with self.assertRaises(SystemExit) as raised:
            regenerate.check(runs, cells=("default", "tps2"))
        self.assertIn("pathIndex on, fieldMerge off, intended pathIndex on, fieldMerge on", str(raised.exception))
        self.assertIn("wire form missing: pathIndex not recorded and commit abc is unknown", str(raised.exception))

    def test_refuses_a_run_off_the_shipped_path(self):
        runs = self.collect({}, {"captured": False}, {"captured": False})
        self.assertTrue(all(r["meta"]["server_env"] == serverenv.record({}) for r in runs))
        runs[0]["meta"]["server_env"] = serverenv.record({"USE_SNAPSHOT_FOR_SYNC": "false"})
        runs[1]["meta"]["server_env"] = None
        with self.assertRaises(SystemExit) as raised:
            regenerate.check(runs, cells=("default", "tps2"))
        self.assertIn("server environment set ({'USE_SNAPSHOT_FOR_SYNC': 'false'})", str(raised.exception))
        self.assertIn("server environment not recorded", str(raised.exception))

    def test_collect_and_tables(self):
        runs = self.collect({}, {"captured": False}, {"captured": False})
        self.assertEqual(len(runs), 18)
        regenerate.check(runs, cells=("default", "tps2"))
        r = next(r for r in runs if r["params"]["cell"] == "tps2" and r["params"]["variant"] == "radius" and r["params"]["repeat"] == 1)
        self.assertEqual(r["metrics"]["bytes_per_recipient_sync"], 40.0)
        self.assertAlmostEqual(r["metrics"]["tick_us_per_room_tick"], 20.0)
        self.assertAlmostEqual(r["metrics"]["sync_us_per_room_sync"], 10.0)
        self.assertEqual(r["metrics"]["bytes_per_recipient_sync_captured"], 160.0)
        self.assertTrue(r["metrics"]["consistency_passed"] and r["metrics"]["replay_passed"])
        self.assertEqual(r["params"]["ticks_per_sync"], 2)
        md = regenerate.tables(runs)
        b = next(r for r in runs if r["params"]["cell"] == "default" and r["params"]["variant"] == "broadcast" and r["params"]["repeat"] == 1)
        self.assertEqual(b["metrics"]["consistency_checks"], 85)
        self.assertIn("| radius 15 | 3.0 | 0.50 | 40.0 | 100.0 | 99.0 | 0.40 |", md)
        self.assertIn("| radius 15 | 10.0 | 10.0 | 4.0 | 2.50 |", md)
        self.assertIn("| 2 tick(s) per sync |", md)

    def refused(self, runs, text):
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs)
        self.assertIn(text, str(cm.exception))

    def test_refuses_failed_gates(self):
        self.refused(self.collect({"gate_ok": False}), "gate_passed is False")
        self.refused(self.collect({"replay_ok": False}), "replay_passed is False")
        self.refused(self.collect({"consistent": False}), "consistency_passed is False")
        self.refused(self.collect({"broadcast_consistent": False}), "broadcast rep1: consistency_passed is False")

    def test_refuses_a_cell_without_a_captured_repeat(self):
        self.refused(self.collect({"captured": False}), "no captured repeat")

    def test_refuses_a_missing_variant(self):
        self.refused(self.collect({"skip": ("tps2", "all")}), "variants ['broadcast', 'radius']")
        self.refused(self.collect({"skip": ("tps2", "broadcast")}), "variants ['all', 'radius']")

    def test_refuses_a_partial_matrix_and_a_missing_repeat(self):
        runs = self.collect({}, {"captured": False}, {"captured": False})
        self.refused(runs, "radius8: missing")
        two = self.collect({}, {"captured": False})
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(two, cells=("default", "tps2"))
        self.assertIn("default: no repeat 3", str(cm.exception))
        self.assertNotIn("missing", str(cm.exception))

    def test_the_matrix_is_run_shs(self):
        out = subprocess.run(["bash", str(TOPIC / "run.sh")], capture_output=True, text=True,
                             env={**os.environ, "DRY_RUN": "1", "REPEAT": "1", "RUN_ID": "matrix"}).stdout
        self.assertEqual({l.split()[1].rsplit("-", 1)[0] for l in out.splitlines() if l.startswith("done ") and "-" in l},
                         set(regenerate.CELLS))

    def test_refuses_repeats_that_dont_rotate_the_order(self):
        self.refused(self.collect({}, {"captured": False}, {"captured": False, "order": "radius-first"}),
                     "default: orders ['all-first', 'radius-first'] over the repeats")

    def test_refuses_dirty_debug_and_wrong_parameters(self):
        self.refused(self.collect({"dirty": True}), "not from a clean tree")
        runs = self.collect({})
        debug = copy.deepcopy(runs)
        debug[0]["meta"]["build_config"] = "debug"
        self.refused(debug, "not a release build")
        wrong = copy.deepcopy(runs)
        wrong[0]["params"]["ticks_per_sync"] = 3
        self.refused(wrong, "the matrix has")
        smoke = copy.deepcopy(runs)
        smoke[0]["params"]["rooms"] = 2
        self.refused(smoke, "rooms 2")

    def test_collect_refuses_a_run_with_another_filter(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        sweep(tmp / "raw", "s1", 1, captured=False)
        path = tmp / "raw" / "s1" / "default-radius.json"
        d = json.loads(path.read_text())
        d["metadata"]["benchmarkConfig"]["visibility"]["VISIBILITY_TEST_FILTER"] = "all"
        path.write_text(json.dumps(d))
        with self.assertRaises(SystemExit):
            collect.collect(tmp / "raw", tmp / "results")

    def test_collect_skips_a_smoke_sweep(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        sweep(tmp / "raw", "s1", 1)
        record = json.loads((tmp / "raw" / "s1" / "run.json").read_text())
        record["onlyCells"] = ["default"]
        (tmp / "raw" / "s1" / "run.json").write_text(json.dumps(record))
        self.assertEqual(collect.collect(tmp / "raw", tmp / "results"), [])


class RunShTests(unittest.TestCase):
    def dry(self, **env):
        e = dict(os.environ, DRY_RUN="1", RUN_ID="dry-test", **env)
        return subprocess.run(["bash", str(TOPIC / "run.sh")], capture_output=True, text=True, env=e)

    def test_dry_run_lists_every_cell_and_check(self):
        p = self.dry(REPEAT="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("EncodingBenchmark --scalability"), 2 * 3 * len(regenerate.CELLS))
        self.assertEqual(p.stdout.count("capcheck.py consistency"), len(regenerate.CELLS))
        self.assertIn("+ unset " + " ".join(serverenv.SERVER_ENV) + "\n", p.stdout)
        self.assertNotIn("USE_SNAPSHOT_FOR_SYNC=false", p.stdout)
        self.assertEqual(p.stdout.count("capcheck.py broadcast-consistency"), len(regenerate.CELLS))
        self.assertEqual(p.stdout.count("replay.py"), 3 * len(regenerate.CELLS))
        self.assertEqual(p.stdout.count("VISIBILITY_TEST_FILTER=broadcast"), 3 * len(regenerate.CELLS))
        for cell, (entities, radius, players, tps) in regenerate.CELLS.items():
            self.assertIn(f"VISIBILITY_TEST_ENTITY_COUNT={entities} VISIBILITY_TEST_VIEW_RADIUS={radius:g} ", p.stdout)
            self.assertIn(f"$OUT/{cell}.consistency.json".replace("$OUT", str(TOPIC / "raw" / "dry-test")), p.stdout)

    def test_capture_zero_skips_checks(self):
        p = self.dry(REPEAT="2", CAPTURE="0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("EncodingBenchmark --scalability"), 3 * len(regenerate.CELLS))
        self.assertNotIn("consistency", p.stdout)

    def test_refusals(self):
        self.assertEqual(self.dry().returncode, 2)
        self.assertEqual(self.dry(REPEAT="1", CELLS="nope").returncode, 2)
        self.assertEqual(self.dry(REPEAT="1", ROOMS="1").returncode, 2)


if __name__ == "__main__":
    unittest.main()
