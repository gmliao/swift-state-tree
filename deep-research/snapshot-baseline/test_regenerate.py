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


if __name__ == "__main__":
    unittest.main()
