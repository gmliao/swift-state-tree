#!/usr/bin/env python3
"""Tests for regenerate.py's room-consistency check, on synthetic results.

Usage: python3 test_regenerate.py
"""
import pathlib, sys, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import regenerate  # noqa: E402


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
        r["meta"] = {"git_sha": sha, "path_index": path_index, "field_merge": field_merge, "source_file": name}
        return r

    def test_the_intended_form_feeds_the_tables_and_the_old_form_is_the_record(self):
        now, old = self.tagged("49fde351", True, True), self.tagged("b8e798b")
        current, record = regenerate.partition([now, old])
        self.assertEqual((current, record), ([now], [old]))

    def test_any_other_form_or_a_missing_one_is_refused(self):
        for r, text in ((self.tagged("49fde351", True, False, "half.json"), "half.json: messagepack-pathhash, pathIndex on, fieldMerge off"),
                        (self.tagged("49fde351", name="unrecorded.json"), "unrecorded.json: wire form missing"),
                        (self.tagged(None, name="nosha.json"), "nosha.json: wire form missing")):
            with self.subTest(text), self.assertRaises(SystemExit) as cm:
                regenerate.partition([r])
            self.assertIn(text, str(cm.exception))


class Repeats(unittest.TestCase):
    """The intended form's tables: per-cell medians over repeats 1..3."""

    def repeats(self, sha="49fde351", repeats=regenerate.REPEATS):
        # The record's cells, relabelled as an intended-form set of repeats; repeat n's cost is n times the record's.
        out = []
        for n in repeats:
            for r in regenerate.load(regenerate.RESULTS):
                r["params"].update(repeat=n, order="delta-first" if n % 2 else "snapshot-first", sweep=f"s{n}")
                r["meta"].update(git_sha=sha, path_index=True, field_merge=True)
                r["metrics"]["avg_cost_per_sync_ms"] *= n
                out.append(r)
        return out

    def test_a_full_set_renders_the_median_of_each_cell(self):
        runs = self.repeats()
        merged = regenerate.merge_repeats(runs)
        self.assertEqual(len(merged), len(runs) // 3)
        one = regenerate.pick(merged, axis="active", players=10, sync_strategy="delta")
        base = regenerate.pick(regenerate.load(regenerate.RESULTS), axis="active", players=10, sync_strategy="delta")
        self.assertEqual(one["metrics"]["avg_cost_per_sync_ms"], 2 * base["metrics"]["avg_cost_per_sync_ms"])
        self.assertEqual(one["metrics"]["bytes_per_sync"], base["metrics"]["bytes_per_sync"])
        self.assertNotIn("repeat", one["params"])
        self.assertIn("| players 10 |", regenerate.tables(merged))

    def test_the_median_ignores_one_outlying_repeat(self):
        runs = self.repeats()
        for r in runs:
            if r["params"]["repeat"] == 3:
                r["metrics"]["bytes_per_sync"] *= 100
        base = regenerate.pick(regenerate.load(regenerate.RESULTS), axis="monsters", monster_cap=50, sync_strategy="full-snapshot")
        one = regenerate.pick(regenerate.merge_repeats(runs), axis="monsters", monster_cap=50, sync_strategy="full-snapshot")
        self.assertEqual(one["metrics"]["bytes_per_sync"], base["metrics"]["bytes_per_sync"])

    def render(self, runs):
        import contextlib, io, unittest.mock
        out = io.StringIO()
        load = regenerate.load
        with unittest.mock.patch.object(regenerate, "load", lambda d: runs if d == regenerate.RESULTS else load(d)), \
                unittest.mock.patch.object(sys, "argv", ["regenerate.py"]), contextlib.redirect_stdout(out):
            regenerate.main()
        return out.getvalue()

    def test_main_renders_the_set_and_refuses_a_partial_one(self):
        md = self.render(self.repeats())
        self.assertIn("Each value is the median over repeats 1–3 of its cell; commit 49fde351.", md)
        self.assertNotIn("No runs in this form yet", md)
        with self.assertRaises(SystemExit) as cm:
            self.render(self.repeats(repeats=(1, 3)))
        self.assertIn("repeat(s) [2] missing", str(cm.exception))

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


if __name__ == "__main__":
    unittest.main()
