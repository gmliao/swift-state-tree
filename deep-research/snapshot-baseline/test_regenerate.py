#!/usr/bin/env python3
"""Tests for regenerate.py's room-consistency check, on synthetic results.

Usage: python3 test_regenerate.py
"""
import json, pathlib, shutil, sys, tempfile, unittest, unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import regenerate  # noqa: E402
import serverenv  # noqa: E402  (on the path through regenerate)


def run(rooms, strategy, per_room, encoding="messagepack-pathhash", repeat=None, players=5):
    axis = "rooms" if rooms == 10 else "rooms-large"
    return {"params": {"axis": axis, "rooms": rooms, "players": players, "encoding": encoding,
                       "sync_strategy": strategy, "repeat": repeat},
            "metrics": {"bytes_per_sync": per_room * rooms}}


class RoomConsistency(unittest.TestCase):
    def check(self, runs):
        regenerate.check_room_consistency(runs)

    def test_mean_index_digits(self):
        self.assertEqual(regenerate.mean_index_digits(10), 1)
        self.assertAlmostEqual(regenerate.mean_index_digits(100), 1.9)
        self.assertAlmostEqual(regenerate.mean_index_digits(500), 2.78)

    def test_delta_within_bound_passes(self):
        self.check([run(10, "delta", 363.0), run(100, "delta", 362.03)])

    def test_delta_over_bound_fails(self):
        with self.assertRaises(SystemExit) as e:
            self.check([run(10, "delta", 363.0), run(100, "delta", 365.0)])
        self.assertIn("delta", str(e.exception.code))

    def test_full_snapshot_growth_from_ids_alone_passes(self):
        # 0.9 more index digits at 100 rooms, 25 bytes per digit: +22.5 B, 0.58 % as measured.
        self.check([run(10, "full-snapshot", 3877.9), run(100, "full-snapshot", 3877.9 + 22.5 + 1.0)])

    def test_full_snapshot_growth_beyond_ids_fails(self):
        with self.assertRaises(SystemExit) as e:
            self.check([run(10, "full-snapshot", 3877.9), run(100, "full-snapshot", 3877.9 + 22.5 + 25.0)])
        self.assertIn("full-snapshot", str(e.exception.code))

    def test_id_term_follows_players_per_room(self):
        # 10 players per room: 100 bytes per digit, 90 B more at 100 rooms.
        self.check([run(10, "full-snapshot", 9000.0, players=10), run(100, "full-snapshot", 9090.0, players=10)])

    def test_each_repeat_checked_on_its_own(self):
        runs = [run(10, "delta", 363.0, repeat=1), run(100, "delta", 362.0, repeat=1),
                run(10, "delta", 363.0, repeat=2), run(100, "delta", 380.0, repeat=2)]
        with self.assertRaises(SystemExit) as e:
            self.check(runs)
        self.assertIn("repeat 2", str(e.exception.code))
        self.assertNotIn("repeat 1", str(e.exception.code))

    def test_unknown_strategy_refused(self):
        with self.assertRaises(SystemExit):
            self.check([run(10, "keyframe", 1.0), run(100, "keyframe", 1.0)])


class WireForm(unittest.TestCase):
    def tagged(self, sha, path_index=None, field_merge=None, name="x.json"):
        r = run(10, "delta", 363.0)
        r["meta"] = {"git_sha": sha, "path_index": path_index, "field_merge": field_merge, "source_file": name,
                     "server_env": serverenv.record({})}
        return r

    def test_the_intended_form_feeds_the_tables_and_the_old_form_is_the_record(self):
        now, old = self.tagged("49fde351", True, True), self.tagged("b8e798b")
        current, record = regenerate.partition([now, old])
        self.assertEqual((current, record), ([now], [old]))

    def test_an_intended_run_off_the_shipped_path_is_refused_but_the_record_is_not(self):
        legacy = self.tagged("49fde351", True, True, "legacy.json")
        legacy["meta"]["server_env"] = serverenv.record({"USE_SNAPSHOT_FOR_SYNC": "false"})
        unrecorded = self.tagged("49fde351", True, True, "unrecorded.json")
        del unrecorded["meta"]["server_env"]
        for r, text in ((legacy, "legacy.json: server environment set ({'USE_SNAPSHOT_FOR_SYNC': 'false'})"),
                        (unrecorded, "unrecorded.json: server environment not recorded")):
            with self.subTest(text), self.assertRaises(SystemExit) as cm:
                regenerate.partition([r])
            self.assertIn(text, str(cm.exception))
        old = self.tagged("b8e798b")
        del old["meta"]["server_env"]
        self.assertEqual(regenerate.partition([old]), ([], [old]))

    def test_any_other_form_or_a_missing_one_is_refused(self):
        for r, text in ((self.tagged("49fde351", True, False, "half.json"), "half.json: messagepack-pathhash, pathIndex on, fieldMerge off"),
                        (self.tagged("49fde351", name="unrecorded.json"), "unrecorded.json: wire form missing"),
                        (self.tagged(None, name="nosha.json"), "nosha.json: wire form missing")):
            with self.subTest(text), self.assertRaises(SystemExit) as cm:
                regenerate.partition([r])
            self.assertIn(text, str(cm.exception))


def record():
    """The pre-refreeze record: the unrepeated runs in results/, whatever repeats sit beside them."""
    return [r for r in regenerate.load(regenerate.RESULTS) if r["params"].get("repeat") is None]


def rerun_bytes():
    """The record's delta bytes at each drift point (the fixture's re-run relabels the record)."""
    return {pt: regenerate.pick(record(), sync_strategy="delta", **cond)["metrics"]["bytes_per_sync"]
            for _, pt, _, cond in regenerate.DRIFT_CELLS}


SR = regenerate.single_room()
# Each form's bytes as a multiple of on-on's, all different (single-room's gate needs that).
SCALE = {"on-on": 1.0, "off-off": 1.4, "on-off": 1.1, "off-on": 1.2, "json": 3.0}


def ablation(directory, sha="49fde351aa", onon=None, offoff=None, mutate=None):
    """single-room-entity-scaling results that pass its own check(): every matrix point, form and
    repeat. on-on at a drift point is the re-run's bytes plus 0.6 (the benchmark truncates);
    `onon`/`offoff` override bytes per point; `mutate(result)` edits each result before it's written."""
    directory.mkdir(parents=True, exist_ok=True)
    rerun = rerun_bytes()
    for cell, points in SR.POINTS.items():
        for pt in points:
            base = (onon or {}).get(pt, rerun.get(pt, 1000.0) + 0.6)
            for form, (encoding, path_index, field_merge) in SR.FORMS.items():
                for repeat in SR.REPEATS:
                    bps = (offoff or {}).get(pt) if form == "off-off" and pt in (offoff or {}) else base * SCALE[form]
                    r = {"meta": {"git_sha": sha, "path_index": path_index, "field_merge": field_merge,
                                  "dynamic_key_compression": True, "git_dirty": False, "swift_version": "6.2.4",
                                  "build_config": "release", "pin_cpus": "0-7", "server_env": serverenv.record({}),
                                  "source_file": f"{cell}-{form}"},
                         "params": {"cell": cell, "form": form, "players": pt[0], "monster_cap": pt[1],
                                    "workload": pt[2], "encoding": encoding, "repeat": repeat, **SR.FIXED},
                         "metrics": {"total_bytes": bps * 200, "bytes_per_sync": bps, "gate_passed": True}}
                    if mutate:
                        mutate(r)
                    (directory / f"{cell}-p{pt[0]}-{form}-rep{repeat}.json").write_text(json.dumps(r))
    return directory


class Repeats(unittest.TestCase):
    """The intended form's tables: per-cell medians over repeats 1..3."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        patcher = unittest.mock.patch.object(regenerate, "ABLATION", ablation(self.tmp / "ablation"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def repeats(self, sha="49fde351", repeats=regenerate.REPEATS):
        # The record's cells, relabelled as an intended-form set of repeats; repeat n's cost is n times the record's.
        out = []
        for n in repeats:
            for r in record():
                r["params"].update(repeat=n, order="delta-first" if n % 2 else "snapshot-first", sweep=f"s{n}")
                r["meta"].update(git_sha=sha, path_index=True, field_merge=True, server_env=serverenv.record({}))
                r["metrics"]["avg_cost_per_sync_ms"] *= n
                out.append(r)
        return out

    def test_a_full_set_renders_the_median_of_each_cell(self):
        runs = self.repeats()
        merged = regenerate.merge_repeats(runs)
        self.assertEqual(len(merged), len(runs) // 3)
        one = regenerate.pick(merged, axis="active", players=10, sync_strategy="delta")
        base = regenerate.pick(record(), axis="active", players=10, sync_strategy="delta")
        self.assertEqual(one["metrics"]["avg_cost_per_sync_ms"], 2 * base["metrics"]["avg_cost_per_sync_ms"])
        self.assertEqual(one["metrics"]["bytes_per_sync"], base["metrics"]["bytes_per_sync"])
        self.assertNotIn("repeat", one["params"])
        self.assertIn("| players 10 |", regenerate.tables(merged))

    def test_the_median_ignores_one_outlying_repeat(self):
        runs = self.repeats()
        for r in runs:
            if r["params"]["repeat"] == 3:
                r["metrics"]["bytes_per_sync"] *= 100
        base = regenerate.pick(record(), axis="monsters", monster_cap=50, sync_strategy="full-snapshot")
        one = regenerate.pick(regenerate.merge_repeats(runs), axis="monsters", monster_cap=50, sync_strategy="full-snapshot")
        self.assertEqual(one["metrics"]["bytes_per_sync"], base["metrics"]["bytes_per_sync"])

    def render(self, runs):
        import contextlib, io
        out = io.StringIO()
        load = regenerate.load
        with unittest.mock.patch.object(regenerate, "load", lambda d: runs if d == regenerate.RESULTS else load(d)), \
                unittest.mock.patch.object(sys, "argv", ["regenerate.py"]), contextlib.redirect_stdout(out):
            regenerate.main()
        return out.getvalue()

    def test_main_renders_the_set_and_refuses_a_partial_one(self):
        md = self.render(self.repeats())
        self.assertIn("Provenance, from the results' meta: commit `49fde351`, dirty flag not recorded; Swift 6.3.2; "
                      "build release.\n\nEach value is the median over repeats 1–3 of its cell.", md)
        self.assertNotIn("No runs in this form yet", md)
        # The intended form's drift table is split by the ablation at its commit; the record's isn't.
        self.assertEqual(md.count("| Cell | archived | off/off, same commit |"), 1)
        self.assertIn("(`single-room-entity-scaling`'s ablation, `49fde35`)", md)
        with unittest.mock.patch.object(regenerate, "ABLATION", ablation(self.tmp / "other", sha="c89bf510")), \
                self.assertRaises(SystemExit) as cm:
            self.render(self.repeats())
        self.assertIn("the split needs one commit", str(cm.exception))
        with self.assertRaises(SystemExit) as cm:
            self.render(self.repeats(repeats=(1, 3)))
        self.assertIn("repeat(s) [2] missing", str(cm.exception))

    def test_the_record_and_the_repeats_side_by_side_in_results(self):
        # The data commit: the host's repeat files land next to the record in results/.
        results = self.tmp / "results"
        results.mkdir()
        for r in regenerate.load(regenerate.RESULTS):
            (results / f"{r['meta']['source_file'].replace('/', '_')}-{len(list(results.iterdir()))}.json").write_text(json.dumps(r))
        n_record = len(record())
        with unittest.mock.patch.object(regenerate, "RESULTS", results):
            for r in self.repeats():
                (results / f"rep{r['params']['repeat']}-{len(list(results.iterdir()))}.json").write_text(json.dumps(r))
            self.assertEqual(len(record()), n_record)
            self.assertEqual(len(self.repeats()), 3 * n_record)
            import contextlib, io
            out = io.StringIO()
            with unittest.mock.patch.object(sys, "argv", ["regenerate.py"]), contextlib.redirect_stdout(out):
                regenerate.main()
        md = out.getvalue()
        self.assertIn("Provenance, from the results' meta: commit `49fde351`, dirty flag not recorded; Swift 6.3.2; "
                      "build release.\n\nEach value is the median over repeats 1–3 of its cell.", md)
        self.assertIn("### Pre-refreeze record (pathIndex off, fieldMerge off;", md)

    def test_repeats_of_cells_from_two_commits_are_refused(self):
        runs = self.repeats()
        cell = (runs[0]["params"]["axis"], runs[0]["params"]["players"])
        for r in runs:
            if (r["params"]["axis"], r["params"]["players"]) == cell:
                r["meta"]["git_sha"] = "c89bf510"
        with self.assertRaises(SystemExit) as cm:
            self.render(runs)
        self.assertIn("results from 2 commits (49fde351, c89bf510)", str(cm.exception))

    def refused(self, runs, text):
        with self.assertRaises(SystemExit) as cm:
            regenerate.merge_repeats(runs)
        self.assertIn(text, str(cm.exception))

    def test_a_missing_repeat_is_refused(self):
        self.refused(self.repeats(repeats=(1, 2)), "repeat(s) [3] missing")
        runs = [r for r in self.repeats() if not (r["params"]["repeat"] == 2 and r["params"]["axis"] == "monsters")]
        self.refused(runs, "repeat(s) [2] missing")

    def test_a_repeat_twice_or_outside_the_set_is_refused(self):
        extra = [r for r in self.repeats() if r["params"]["repeat"] == 1][:1]
        self.refused(self.repeats() + extra, "repeat(s) [1] more than once")
        self.refused(self.repeats(repeats=(1, 2, 3, 4)), "repeat 4, expected one of [1, 2, 3]")
        unrepeated = self.repeats()
        unrepeated[0]["params"]["repeat"] = None
        self.refused(unrepeated, "repeat None")

    def test_repeats_from_different_commits_are_refused(self):
        runs = self.repeats()
        for r in runs:
            if r["params"]["repeat"] == 3:
                r["meta"]["git_sha"] = "c89bf510"
        self.refused(runs, "repeats from different commits")


class DriftSplit(unittest.TestCase):
    """The intended form's drift table: archived -> off/off (code changes); off/off -> on/on (wire form),
    both from single-room's ablation."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def rerun(self, sha="49fde351"):
        runs = record()
        for r in runs:
            r["meta"]["git_sha"] = sha
        return runs

    def split(self, **kw):
        runs = self.rerun()
        return runs, regenerate.off_off(runs, "49fde351", ablation(self.tmp / "a", **kw))

    def test_the_table_splits_code_changes_from_the_wire_form(self):
        # cap 4: archived 828; off-off 587.0; on-on 425.6, which the benchmark truncates to the re-run's 425.
        runs = self.rerun()
        for r in runs:
            if r["params"].get("axis") == "monsters" and r["params"]["monster_cap"] == 4 and r["params"]["sync_strategy"] == "delta":
                r["metrics"]["bytes_per_sync"] = 425.0
        offoff = regenerate.off_off(runs, "49fde351", ablation(self.tmp / "b", onon={(5, 4, "idle"): 425.6},
                                                                offoff={(5, 4, "idle"): 587.0}))
        self.assertEqual(offoff[0], "49fde351aa")
        md = regenerate.tables(runs, offoff=offoff)
        self.assertIn("| Cell | archived | off/off, same commit | re-run (on/on) | code changes | wire form |", md)
        # Code changes 828 -> 587; the wire form 587 -> 425.6 (single-room on both sides), not 587 -> 425.
        self.assertIn("| monster cap 4 | 828 | 587 | 425 | -29.1% | -27.5% |", md)
        self.assertIn("How 818 → 587 splits among the changes was not measured.", md)
        self.assertIn("truncated to whole bytes", md)
        # The truncation bound: max over the cells of 100 × off/off / archived²; cap 4 (587 / 828²) is the largest.
        self.assertIn("by at most 0.09 percentage points", md)
        self.assertNotIn("| drift |", md)

    def test_the_record_keeps_its_archive_comparison(self):
        md = regenerate.tables(record())
        self.assertIn("| monster cap 4 | 828 | 828 | +0.0% |", md)
        self.assertNotIn("off/off", md)

    def refused(self, text, commit="49fde351", runs=None, **kw):
        runs = self.rerun() if runs is None else runs
        with self.assertRaises(SystemExit) as cm:
            regenerate.off_off(runs, commit, ablation(self.tmp / f"a{len(list(self.tmp.iterdir()))}", **kw))
        self.assertIn(text, str(cm.exception))

    def test_an_ablation_at_another_commit_is_refused(self):
        self.refused("the split needs one commit", sha="c89bf510")
        self.refused("the split needs one commit", commit="49fde35", sha="49fde3")  # 6 digits: too short to match

    def test_single_rooms_own_gates_run(self):
        def unpinned(r):
            r["meta"]["pin_cpus"] = None
        self.refused("unpinned", mutate=unpinned)
        def another_form(r):
            if r["params"]["form"] == "off-off":
                r["meta"]["path_index"] = True
        self.refused("its label says", mutate=another_form)
        def drifting(r):
            if r["params"]["form"] == "off-off" and r["params"]["repeat"] == 2:
                r["metrics"]["bytes_per_sync"] += 1
                r["metrics"]["total_bytes"] += 200
        self.refused("bytes differ between repeats", mutate=drifting)
        with self.assertRaises(SystemExit) as cm:
            regenerate.off_off(self.rerun(), "49fde351", self.tmp / "empty")
        self.assertIn("no single-room-entity-scaling results", str(cm.exception))

    def test_a_drift_point_without_both_forms_is_refused_even_past_single_rooms_gates(self):
        # single-room's check() refuses a partial matrix; the local presence check is the backstop if
        # that topic's matrix ever drops a drift point.
        directory = ablation(self.tmp / "partial")
        (directory / "active-players-p50-off-off-rep1.json").unlink()
        (directory / "active-players-p50-off-off-rep2.json").unlink()
        lenient = regenerate.single_room()
        lenient.check = lambda runs: None
        with unittest.mock.patch.object(regenerate, "single_room", lambda: lenient), self.assertRaises(SystemExit) as cm:
            regenerate.off_off(self.rerun(), "49fde351", directory)
        self.assertIn("active players (50, 4, 'active'): single-room has forms", str(cm.exception))

    def test_on_on_must_be_the_rerun_measurement(self):
        # Exactly the floor: 828.99 is the re-run's 828; 829.0 and 827.9 aren't.
        self.split(onon={(5, 4, "idle"): 828.99})
        self.refused("not the same measurement", onon={(5, 4, "idle"): 829.0})
        self.refused("not the same measurement", onon={(5, 4, "idle"): 827.9})

    def test_drift_cells_from_two_commits_are_refused(self):
        runs = self.rerun()
        regenerate.pick(runs, axis="active", players=50, sync_strategy="delta")["meta"]["git_sha"] = "c89bf510"
        with self.assertRaises(SystemExit) as cm:
            regenerate.drift_commit(runs)
        self.assertIn("the split needs one", str(cm.exception))
        self.assertEqual(regenerate.drift_commit(self.rerun()), "49fde351")

    def test_same_commit_needs_seven_hex_digits(self):
        self.assertTrue(regenerate.same_commit("49fde35", "49fde351aa"))
        self.assertFalse(regenerate.same_commit("49fde3", "49fde351aa"))
        self.assertFalse(regenerate.same_commit("49fde35", "49fde36"))
        self.assertFalse(regenerate.same_commit(None, "49fde351"))


class Units(unittest.TestCase):
    def test_the_cost_columns_name_their_unit(self):
        # avgCostPerSyncMs is one room's 2 ticks + 1 sync, serial; bytesPerSync is the whole sync.
        md = regenerate.tables(record())
        unit = "avgCostPerSyncMs (iteration wall time ÷ rooms; 2 ticks + 1 sync; ms)"
        header = next(line for line in md.splitlines() if line.startswith("| Cell | delta bytesPerSync"))
        self.assertIn(f"| delta {unit} | full {unit} |", header)
        self.assertNotIn("avgCostPerSyncMs |", md)


if __name__ == "__main__":
    unittest.main()
