#!/usr/bin/env python3
"""Tests for the wire ablation's scripts: the gates, the cross-check, the collector, the frame
hash and run.sh's dry run (stdlib only; run.sh's tests need bash).

Run: python3 deep-research/wire-ablation-2026-11/test_topic.py
"""
import base64, json, os, pathlib, subprocess, sys, tempfile, unittest
from unittest import mock

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import collect, frames, regenerate, runmeta  # noqa: E402

POINTS = {"idle-players": [(10, 4, "idle")], "joint": [(20, 20, "active")]}
BASE = {"idle-players": 160_000, "joint": 3_700_000}


def meta(**over):
    m = {"git_sha": "abc1234", "git_dirty": False, "sources_tree": regenerate.SOURCES_TREE,
         "package_tree": regenerate.PACKAGE_TREE, "swift_version": "Swift version 6.2.4 (swift-6.2.4-RELEASE)",
         "node_version": "v24.22.2", "server_env": {k: None for k in regenerate.serverenv.SERVER_ENV},
         "pin_cpus": "0-7", "build_config": "release", "path_index": True, "field_merge": True}
    m.update(over)
    return m


def run(cell, pt, form, rep, total=None, sync_ms=0.5):
    _, dt, dk = regenerate.FORMS[form]
    if total is None:
        total = BASE[cell] * (2 if form.startswith("oj") else 1) + (0 if dk else 9_000)
    players, cap, workload = pt
    return {
        "meta": meta(dirty_tracking=dt, dynamic_key_compression=dk, source_file=f"s{rep}/{cell}-{form}.json"),
        "params": {"cell": cell, "form": form, "players": players, "monster_cap": cap, "workload": workload,
                   "rooms": 1, "encoding": regenerate.FORMS[form][0], "sync_strategy": "delta", "parallel": "false",
                   "ticks_per_sync": 2, "iterations": 200, "repeat": rep, "order": regenerate.ORDER[rep], "sweep": f"s{rep}"},
        "metrics": {"total_bytes": total, "bytes_per_sync": total / 200, "bytes_per_player_per_sync": total / 200 / players,
                    "sync_ms_per_sync": sync_ms * (1.3 if dt == "off" else 1.0), "iteration_cpu_ms": 2.0, "final_monster_count": cap},
    }


def capture(cell, pt, form, sha=None):
    players, cap, workload = pt
    _, _, dk = regenerate.FORMS[form]
    return {
        "meta": meta(deterministic_hashing=True, source_file=f"cap/{cell}-{form}"),
        "params": {"cell": cell, "form": form, "players": players, "monster_cap": cap, "workload": workload, "rooms": 1, "sweep": "cap"},
        "metrics": {"gate_passed": True, "gate_comparisons": 1000,
                    "frames_sha256": sha or f"{cell}-{form[:2]}-{'dk' if dk else 'nodk'}", "frames": 400, "syncs": 200},
    }


def matrix():
    runs = [run(c, pt, f, rep) for c, pts in POINTS.items() for pt in pts for f in regenerate.FORMS for rep in regenerate.REPEATS]
    caps = [capture(c, pt, f) for c, pts in POINTS.items() for pt in pts for f in regenerate.FORMS]
    return runs, caps


def edit(items, cell, form, rep=None, fn=lambda r: None):
    for r in items:
        if r["params"]["cell"] == cell and r["params"]["form"] == form and (rep is None or r["params"].get("repeat") == rep):
            fn(r)
    return items


class Gates(unittest.TestCase):
    def refused(self, runs, caps, text):
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs, caps, points=POINTS)
        self.assertIn(text, str(cm.exception))

    def test_a_full_matrix_passes_and_renders(self):
        runs, caps = matrix()
        regenerate.check(runs, caps, points=POINTS)
        md = regenerate.tables(runs, points=POINTS)
        self.assertIn("### Bytes per sync", md)
        self.assertIn("+30.0 %", md)  # tracking off's sync time over on's, in the fixture
        self.assertIn("0.500 [0.500–0.500]", md)

    def test_dirty_tracking_changing_the_bytes_is_refused(self):
        runs, caps = matrix()
        edit(runs, "joint", "mp-nodt-dk", 3, lambda r: r["metrics"].update(total_bytes=r["metrics"]["total_bytes"] + 1))
        self.refused(runs, caps, "dirty tracking changed the bytes in repeat 3")

    def test_dirty_tracking_changing_the_frames_is_refused(self):
        runs, caps = matrix()
        edit(caps, "joint", "mp-nodt-nodk", fn=lambda c: c["metrics"].update(frames_sha256="other"))
        self.refused(runs, caps, "the same counts (400 frames in 200 syncs), other bytes, targets, order or syncs")
        runs, caps = matrix()
        edit(caps, "joint", "mp-nodt-dk", fn=lambda c: c["metrics"].update(frames=401))
        self.refused(runs, caps, "400 frames in 200 syncs with it on, 401 in 200 off")

    def test_dynamic_keys_off_must_send_more_in_every_repeat(self):
        runs, caps = matrix()
        edit(runs, "idle-players", "oj-nodk", 2, lambda r: r["metrics"].update(total_bytes=2 * BASE["idle-players"]))
        self.refused(runs, caps, "oj-nodk 320000 bytes not more than oj-dk 320000")

    def test_bytes_must_match_across_repeats(self):
        runs, caps = matrix()
        for form in ("mp-dt-dk", "mp-nodt-dk"):  # equal across tracking, so only gate 4 fires
            edit(runs, "joint", form, 4, lambda r: r["metrics"].update(total_bytes=r["metrics"]["total_bytes"] + 5))
        self.refused(runs, caps, "joint p20 mp-dt-dk: bytes differ between repeats")

    def test_a_missing_repeat_or_capture_is_refused(self):
        runs, caps = matrix()
        runs = [r for r in runs if not (r["params"]["form"] == "oj-dk" and r["params"]["repeat"] == 2)]
        caps = [c for c in caps if c["params"]["form"] != "mp-dt-nodk"]
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs, caps, points=POINTS)
        self.assertIn("oj-dk: 0 results for repeat 2", str(cm.exception))
        self.assertIn("mp-dt-nodk: no capture", str(cm.exception))

    def test_the_recorded_modes_order_and_flags_must_be_the_forms(self):
        runs, caps = matrix()
        edit(runs, "joint", "mp-nodt-dk", 1, lambda r: r["meta"].update(dirty_tracking="auto"))
        edit(runs, "joint", "oj-nodk", 2, lambda r: r["params"].update(order="forward"))
        edit(runs, "joint", "oj-dk", 1, lambda r: r["meta"].update(field_merge=False))
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs, caps, points=POINTS)
        text = str(cm.exception)
        self.assertIn("ran dirty tracking 'auto'", text)
        self.assertIn("ran 'forward' order, repeat 2 is 'reverse'", text)
        self.assertIn("field merge False", text)

    def test_the_run_must_be_clean_pinned_and_on_the_rerun_sources(self):
        cases = [
            (lambda m: m.update(git_dirty=True), "not from a clean tree"),
            (lambda m: m.update(pin_cpus=""), "unpinned"),
            (lambda m: m.update(swift_version="Swift version 6.3.2"), "not the pinned 6.2.4"),
            (lambda m: m.update(sources_tree="deadbeef"), "not 75222b87's"),
            (lambda m: m["server_env"].update(DYNAMIC_KEY_COMPRESSION="false"), "server environment set"),
        ]
        for change, text in cases:
            with self.subTest(text):
                runs, caps = matrix()
                edit(runs, "idle-players", "mp-dt-dk", 1, lambda r: change(r["meta"]))
                self.refused(runs, caps, text)

    def test_a_capture_must_pass_verify_views_under_deterministic_hashing(self):
        runs, caps = matrix()
        edit(caps, "joint", "oj-nodk", fn=lambda c: c["metrics"].update(gate_passed=False))
        edit(caps, "joint", "oj-dk", fn=lambda c: c["meta"].update(deterministic_hashing=False))
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs, caps, points=POINTS)
        self.assertIn("capture joint p20 oj-nodk: the verify-views gate failed", str(cm.exception))
        self.assertIn("capture joint p20 oj-dk: not run under deterministic hashing", str(cm.exception))

    def test_results_from_two_commits_are_refused(self):
        runs, caps = matrix()
        edit(runs, "joint", "oj-dk", 3, lambda r: r["meta"].update(git_sha="fff9999"))
        self.refused(runs, caps, "results from 2 commits")


class CrossCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = pathlib.Path(self.tmp.name)
        self.runs, _ = matrix()
        for cell, pts in POINTS.items():
            for pt in pts:
                self.write(cell, pt)

    def write(self, cell, pt, **over):
        players, cap, workload = pt
        doc = {"meta": {"git_sha": "1234abcd", "path_index": True, "field_merge": True, "dynamic_key_compression": True},
               "params": {"players": players, "monster_cap": cap, "workload": workload, "rooms": 1, "iterations": 200,
                          "ticks_per_sync": 2, "encoding": "messagepack-pathhash", "sync_strategy": "delta", "parallel": False},
               "metrics": {"total_bytes": BASE[cell]}}
        for key, value in over.items():
            section, field = key.split("__")
            doc[section][field] = value
        (self.dir / f"{cell}-p{players}-on-on-rep1.json").write_text(json.dumps(doc), encoding="utf-8")

    def tree(self, commit, path):
        return {"Sources": regenerate.SOURCES_TREE, "Package.swift": regenerate.PACKAGE_TREE}[path]

    def cross(self, tree=None):
        regenerate.cross_check(self.runs, single_room=self.dir, tree=tree or self.tree, points=POINTS)

    def refused(self, text, tree=None):
        with self.assertRaises(SystemExit) as cm:
            self.cross(tree)
        self.assertIn(text, str(cm.exception))

    def test_equal_bytes_parameters_and_trees_pass(self):
        self.cross()

    def test_another_sources_tree_is_refused(self):
        self.refused("not 75222b87's", tree=lambda commit, path: "0" * 40)

    def test_unresolvable_commit_is_refused(self):
        self.refused("whose trees are None/None", tree=lambda commit, path: None)

    def test_a_parameter_drift_is_refused_before_the_bytes(self):
        self.write("joint", (20, 20, "active"), params__ticks_per_sync=4)
        self.refused("ticks_per_sync 4 in single-room, 2 here")

    def test_other_knobs_in_single_room_are_refused(self):
        self.write("joint", (20, 20, "active"), meta__dynamic_key_compression=False)
        self.refused("dynamic keys False")

    def test_unequal_bytes_are_refused(self):
        self.write("idle-players", (10, 4, "idle"), metrics__total_bytes=BASE["idle-players"] + 1)
        self.refused("160000 bytes here, 160001 in single-room's on-on")

    def test_a_missing_single_room_result_is_refused(self):
        (self.dir / "joint-p20-on-on-rep1.json").unlink()
        self.refused("single-room-entity-scaling's rerun results aren't committed")


def write_capture(directory, label, rooms):
    """rooms: [[[(to, bytes), ...] per sync] per room]"""
    run = directory / label
    run.mkdir(parents=True)
    for i, syncs in enumerate(rooms):
        lines = [json.dumps({"header": True, "format": "x"})]
        for n, frames_ in enumerate(syncs):
            lines.append(json.dumps({"sync": n, "frames": [{"to": to, "data": base64.b64encode(b).decode()} for to, b in frames_],
                                     "projections": {"p1": {"v": n}}}))
        (run / f"room-{i}.ndjson").write_text("\n".join(lines) + "\n", encoding="utf-8")


class Frames(unittest.TestCase):
    def hash_of(self, rooms, projection=None):
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            write_capture(d, "mp-delta-r1-p5-m4-serial", rooms)
            if projection is not None:
                path = d / "mp-delta-r1-p5-m4-serial" / "room-0.ndjson"
                path.write_text(path.read_text(encoding="utf-8").replace('"v": 0', f'"v": {projection}'), encoding="utf-8")
            return frames.hashes(d)["mp-delta-r1-p5-m4-serial"]

    def test_the_same_frames_hash_alike_and_projections_dont_count(self):
        rooms = [[[("*", b"\x01\x02"), ("s:a", b"\x03")], [("*", b"\x04")]]]
        a, b = self.hash_of(rooms), self.hash_of(rooms, projection=9)
        self.assertEqual(a, b)
        self.assertEqual((a["frames"], a["syncs"]), (3, 2))

    def test_a_byte_a_target_or_the_order_changes_the_hash(self):
        base = self.hash_of([[[("*", b"\x01\x02"), ("s:a", b"\x03")]]])["sha256"]
        for rooms in ([[[("*", b"\x01\x03"), ("s:a", b"\x03")]]],
                      [[[("*", b"\x01\x02"), ("s:b", b"\x03")]]],
                      [[[("s:a", b"\x03"), ("*", b"\x01\x02")]]],
                      [[[("*", b"\x01"), ("s:a", b"\x02\x03")]]]):
            with self.subTest(rooms):
                self.assertNotEqual(self.hash_of(rooms)["sha256"], base)


    def test_a_frame_moved_to_the_next_sync_changes_the_hash(self):
        one = self.hash_of([[[("*", bytes([1])), ("*", bytes([2]))], []]])
        two = self.hash_of([[[("*", bytes([1]))], [("*", bytes([2]))]]])
        self.assertEqual((one["frames"], one["syncs"]), (two["frames"], two["syncs"]))
        self.assertNotEqual(one["sha256"], two["sha256"])


class Collect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raw, self.results = pathlib.Path(self.tmp.name) / "raw", pathlib.Path(self.tmp.name) / "results"

    def record(self, name, kind, repeat, **over):
        d = self.raw / name
        d.mkdir(parents=True)
        rec = {"runId": name, "kind": kind, "repeat": repeat, "order": runmeta.ORDER.get(repeat, "forward"),
               "deterministicHashing": kind == "capture", "pinCpus": "0-7", "serverEnv": {}, "onlyCells": None, "onlyForms": None,
               "git": {"commit": "abc1234", "dirty": False, "sourcesTree": "t1", "packageTree": "t2"},
               "swiftVersion": "Swift version 6.2.4", "nodeVersion": "v24", "superseded": None, "cells": []}
        rec.update(over)
        (d / "run.json").write_text(json.dumps(rec), encoding="utf-8")
        return d

    def bench(self, directory, tag, form_flags, players=(10,)):
        cmd = ["EncodingBenchmark", "--scalability", *form_flags.split(), "--room-counts", "1", "--iterations", "200",
               "--ticks-per-sync", "2", "--parallel", "false", "--players-per-room-list", ",".join(map(str, players)), "--monster-cap", "4"]
        doc = {"metadata": {"commandLine": cmd, "timestampUTC": "t", "dirtyTracking": "off", "dynamicKeyCompression": True,
                            "pathIndex": True, "fieldMerge": True, "git": {"commit": "abc1234"},
                            "build": {"configuration": "release", "swiftVersion": "Swift version 6.2.4"}},
               "results": [{"rooms": 1, "playersPerRoom": p, "serial": {"totalBytes": 2000 * p, "syncMs": 100.0, "cpuMs": 400.0,
                                                                         "finalMonsterCount": 4}} for p in players]}
        (directory / f"{tag}.json").write_text(json.dumps(doc), encoding="utf-8")

    def test_measured_and_capture_invocations_become_results(self):
        d = self.record("s2", "measured", 2)
        self.bench(d, "idle-players-mp-nodt-dk", "--format messagepack-pathhash --dirty-tracking off", players=(10, 20))
        c = self.record("cap", "capture", None)
        (c / "idle-players-mp-nodt-dk.views.json").write_text(json.dumps({"runs": {
            "x-r1-p10-m4-serial": [{"decodeErrors": 0, "differences": [], "comparisons": 50}],
            "x-r1-p20-m4-serial": [{"decodeErrors": 0, "differences": ["d"], "comparisons": 50}]}}), encoding="utf-8")
        (c / "idle-players-mp-nodt-dk.frames.json").write_text(json.dumps({
            "x-r1-p10-m4-serial": {"sha256": "aa", "frames": 4, "syncs": 2},
            "x-r1-p20-m4-serial": {"sha256": "bb", "frames": 4, "syncs": 2}}), encoding="utf-8")
        written = collect.collect(self.raw, self.results)
        self.assertEqual(sorted(written), ["capture/idle-players-p10-mp-nodt-dk", "capture/idle-players-p20-mp-nodt-dk",
                                           "idle-players-p10-mp-nodt-dk-rep2", "idle-players-p20-mp-nodt-dk-rep2"])
        r = json.loads((self.results / "idle-players-p20-mp-nodt-dk-rep2.json").read_text(encoding="utf-8"))
        self.assertEqual((r["params"]["order"], r["params"]["parallel"], r["meta"]["sources_tree"]), ("reverse", "false", "t1"))
        self.assertEqual((r["metrics"]["sync_ms_per_sync"], r["metrics"]["iteration_cpu_ms"], r["metrics"]["bytes_per_sync"]), (0.5, 2.0, 200.0))
        cap = json.loads((self.results / "capture" / "idle-players-p20-mp-nodt-dk.json").read_text(encoding="utf-8"))
        self.assertEqual((cap["metrics"]["gate_passed"], cap["metrics"]["frames_sha256"], cap["meta"]["deterministic_hashing"]), (False, "bb", True))

    def test_smoke_runs_are_skipped_and_a_repeat_claimed_twice_is_refused(self):
        self.record("smoke", "measured", 1, onlyCells=["joint"])
        self.assertEqual(collect.collect(self.raw, self.results), [])
        self.record("a", "measured", 3)
        self.record("b", "measured", 3)
        with self.assertRaises(SystemExit) as cm:
            collect.collect(self.raw, self.results)
        self.assertIn("repeat 3 is claimed by both a and b", str(cm.exception))


class RunSh(unittest.TestCase):
    def dry(self, **env):
        full = dict(os.environ, DRY_RUN="1", RUN_ID="test", PIN_CPUS="", **env)
        return subprocess.run(["bash", str(TOPIC / "run.sh")], env=full, capture_output=True, text=True, encoding="utf-8")

    def forms_of(self, out, cell):
        return [line.split(f"{cell}-", 1)[1].split()[0].split(".")[0] for line in out.splitlines()
                if line.startswith("+ status") and f" {cell}-" in line]

    def test_repeats_run_the_forms_in_abba_order(self):
        forward = "mp-dt-dk mp-dt-nodk mp-nodt-dk mp-nodt-nodk oj-dk oj-nodk".split()
        for repeat, order in (("1", forward), ("2", forward[::-1]), ("3", forward[::-1]), ("4", forward)):
            with self.subTest(repeat):
                p = self.dry(REPEAT=repeat)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.forms_of(p.stdout, "joint"), order)
                self.assertNotIn("--capture-views", p.stdout)
                self.assertNotIn("SWIFT_DETERMINISTIC_HASHING", p.stdout)

    def test_the_capture_block_hashes_frames_under_deterministic_hashing(self):
        p = self.dry(CAPTURE_ONLY="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        captures = [line for line in p.stdout.splitlines() if "--capture-views" in line]
        self.assertEqual(len(captures), 7 * 6)
        self.assertTrue(all(line.startswith("+ SWIFT_DETERMINISTIC_HASHING=1 ") for line in captures))
        self.assertIn("frames.py", p.stdout)
        self.assertIn("--dirty-tracking off --dynamic-key-compression off", p.stdout)

    def test_refusals(self):
        for env, text in (({"REPEAT": "5"}, "REPEAT must be 1, 2, 3 or 4"), ({}, "REPEAT is required"),
                          ({"CAPTURE_ONLY": "1", "REPEAT": "1"}, "CAPTURE_ONLY=1 takes no REPEAT"),
                          ({"REPEAT": "1", "FORMS": "mp-x"}, "unknown form")):
            with self.subTest(env):
                p = self.dry(**env)
                self.assertEqual(p.returncode, 2)
                self.assertIn(text, p.stderr)


class RunMeta(unittest.TestCase):
    def test_kinds_repeats_and_order(self):
        # No git, swift or node: the record's tool outputs are stubbed.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(runmeta, "output", lambda *cmd: None):
            d = pathlib.Path(tmp)
            runmeta.start(d / "m", "m", "3", "reverse", "0", "0-7", "0", "0")
            rec = runmeta.load(d / "m")
            self.assertEqual((rec["kind"], rec["repeat"], rec["order"], rec["deterministicHashing"]), ("measured", 3, "reverse", False))
            self.assertEqual(rec["git"], {"commit": None, "dirty": None, "sourcesTree": None, "packageTree": None})
            runmeta.start(d / "c", "c", "0", "forward", "1", "0-7", "0", "0")
            self.assertEqual(runmeta.load(d / "c")["deterministicHashing"], True)
            with self.assertRaises(SystemExit):
                runmeta.start(d / "x", "x", "5", "forward", "0", "0-7", "0", "0")
            with self.assertRaises(SystemExit):
                runmeta.start(d / "y", "y", "2", "forward", "0", "0-7", "0", "0")


if __name__ == "__main__":
    unittest.main()
