#!/usr/bin/env python3
"""Tests for analysis.py on synthetic fixtures: python3 -m unittest test_analysis (stdlib)."""
import gzip
import json
import math
import pathlib
import tempfile
import unittest

import analysis as a

T0 = 1_800_000_000_000  # the apply, ms since epoch


def timeline_entries(applied=T0, lifted=T0 + 60_000, profile="BO75"):
    return [
        {"action": "apply", "profile": profile, "wallMsAfter": applied},
        {"action": "lift", "profile": "P0", "wallMsAfter": lifted},
    ]


class TimelineTests(unittest.TestCase):
    def write(self, entries):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "t.json").write_text(json.dumps(entries))
        return d / "t.json"

    def test_segments_are_half_open_around_apply_and_lift(self):
        t = a.read_timeline(self.write(timeline_entries()))
        self.assertEqual(t.profile, "BO75")
        self.assertEqual(t.segment_of(T0 - 30_000), "baseline")
        self.assertIsNone(t.segment_of(T0 - 30_001))
        self.assertEqual(t.segment_of(T0 - 1), "baseline")
        self.assertEqual(t.segment_of(T0), "impaired")
        self.assertEqual(t.segment_of(T0 + 60_000), "recovery")
        self.assertEqual(t.segment_of(T0 + 60_000 + 89_999), "recovery")
        self.assertIsNone(t.segment_of(T0 + 150_000))

    def test_a_timeline_without_exactly_one_apply_and_lift_is_refused(self):
        with self.assertRaises(ValueError):
            a.read_timeline(self.write(timeline_entries()[:1]))
        with self.assertRaises(ValueError):
            a.read_timeline(self.write(timeline_entries() + timeline_entries()))
        with self.assertRaises(ValueError):
            a.read_timeline(self.write(timeline_entries(lifted=T0)))


class WindowTests(unittest.TestCase):
    def test_an_action_counts_in_the_window_of_its_intended_send_not_its_answer(self):
        records = [
            {"r": "rtt", "k": "c1", "intendedAt": T0 + 100, "sentAt": T0 + 100, "respondedAt": T0 + 2_500},
            {"r": "rtt", "k": "c1", "intendedAt": T0 + 1_200, "sentAt": T0 + 1_200, "respondedAt": None, "end": "phaseEnd"},
            {"r": "rtt", "k": "c1", "intendedAt": T0 + 1_300, "sentAt": T0 + 1_300, "respondedAt": T0 + 7_000},
        ]
        ws = a.windows(records, T0, T0 + 3_000)
        self.assertEqual([w.sends for w in ws], [1, 2, 0])
        self.assertEqual(ws[0].rtt_ms, [2_400])
        self.assertEqual(ws[1].unanswered, 1)
        self.assertEqual(ws[1].late, 1, "answered 5.7 s after its intended send")

    def test_move_events_and_update_gaps(self):
        records = [{"r": "input", "k": "c1", "sentAt": T0 + i, "seenAt": T0 + i + 40} for i in range(9)]
        records.append({"r": "input", "k": "c1", "sentAt": T0 + 500, "seenAt": None, "end": "timedOut"})
        records += [
            {"r": "update", "k": "c1", "t": T0 + 100, "gapMs": None},
            {"r": "update", "k": "c1", "t": T0 + 200, "gapMs": 100},
            {"r": "update", "k": "c1", "t": T0 + 900, "gapMs": 700},
        ]
        (w,) = a.windows(records, T0, T0 + 1_000)
        self.assertEqual((w.inputs_sent, w.inputs_seen), (10, 9))
        self.assertEqual(w.summary()["inputP99"], 40)
        self.assertEqual(w.gaps_ms, [100, 700], "the first update has no gap")

    def test_joined_counts_connections_joined_for_the_whole_window_across_a_reconnect(self):
        records = [
            {"r": "join", "k": "c1", "t": T0 - 5_000, "land": "l1", "player": "p1"},
            {"r": "close", "key": "c1", "t": T0 + 1_500, "joined": True, "initiator": "server", "player": "p1"},
            {"r": "join", "k": "c1", "t": T0 + 3_200, "land": "l1", "player": "p1"},
            {"r": "join", "k": "c2", "t": T0 - 5_000, "land": "l1", "player": "p2"},
        ]
        ws = a.windows(records, T0, T0 + 5_000)
        self.assertEqual([w.joined for w in ws], [2, 1, 1, 1, 2])
        spans = a.joined_intervals(records)
        self.assertEqual(spans["c1"], [(T0 - 5_000, T0 + 1_500), (T0 + 3_200, math.inf)])


class GroupTests(unittest.TestCase):
    def test_a_group_with_lands_keeps_only_its_connections(self):
        records = [
            {"r": "join", "k": "c1", "t": T0, "land": "mixed-1", "player": "p1"},
            {"r": "join", "k": "c2", "t": T0, "land": "healthy-1", "player": "p2"},
            {"r": "update", "k": "c1", "t": T0 + 100, "gapMs": 100},
            {"r": "update", "k": "c2", "t": T0 + 100, "gapMs": 100},
            {"r": "close", "key": "c2", "t": T0 + 200, "joined": True, "initiator": "server", "player": "p2"},
        ]
        kept = a.in_lands(records, {"mixed-1"})
        self.assertEqual([(r["r"], r.get("k", r.get("key"))) for r in kept], [("join", "c1"), ("update", "c1")])


class BandHealthRecoveryTests(unittest.TestCase):
    def window(self, **overrides):
        w = {"joined": 4, "sends": 40, "rttP99": 10, "unanswered": 0, "inputsSent": 60,
             "inputsSeen": 60, "inputP99": 50, "gapP99": 120}
        w.update(overrides)
        return w

    def test_band_is_the_largest_repeat_p95(self):
        repeats = [
            [self.window(rttP99=v) for v in range(1, 101)],    # p95 = 95
            [self.window(rttP99=v) for v in range(1, 21)],     # p95 = 19
            [self.window(rttP99=None)],                        # no value: skipped
        ]
        self.assertEqual(a.band(repeats)["rttP99"], 95)

    def test_health(self):
        edges = {"rttP99": 20, "inputP99": 80, "gapP99": 150}
        h = lambda **o: a.health(self.window(**o), target=4, send_target=40, edges=edges)
        self.assertEqual(h(), "healthy")
        self.assertEqual(h(inputsSent=49, inputsSeen=49), "insufficient")
        self.assertEqual(h(joined=3), "unhealthy")
        self.assertEqual(h(sends=37), "unhealthy", "below 95 % of the send target")
        self.assertEqual(h(sends=38), "healthy")
        self.assertEqual(h(inputsSeen=59), "unhealthy", "below 99 % seen")
        self.assertEqual(h(unanswered=1), "unhealthy")
        self.assertEqual(h(rttP99=21), "unhealthy")
        self.assertEqual(h(gapP99=150), "healthy", "at the band edge is within it")

    def test_recovery_needs_five_consecutive_healthy_windows(self):
        starts = [T0 + i * 1_000 for i in range(12)]
        states = ["unhealthy", "healthy", "healthy", "insufficient", "healthy", "healthy",
                  "healthy", "healthy", "healthy", "unhealthy", "healthy", "healthy"]
        self.assertEqual(a.recovery_ms(states, starts, T0), 4_000)
        self.assertIsNone(a.recovery_ms(states[:8], starts[:8], T0))


class IngestTests(unittest.TestCase):
    def test_ingest_builds_per_group_windows_with_segments(self):
        d = pathlib.Path(tempfile.mkdtemp()) / "u-bo75-r1"
        (d / "samples" / "lt-client").mkdir(parents=True)
        (d / "impairment-timeline.json").write_text(json.dumps(timeline_entries()))
        (d / "run.json").write_text(json.dumps({
            "meta": {"git_sha": "abc"},
            "params": {"rooms": 1, "population": "U"},
            "groups": {"impaired": {"instance": "lt-client", "target": 1, "sendTargetPerS": 10}},
        }))
        records = [
            {"r": "join", "k": "c1", "t": T0 - 40_000, "land": "l1", "player": "p1"},
            {"r": "rtt", "k": "c1", "intendedAt": T0 - 10_000, "sentAt": T0 - 10_000, "respondedAt": T0 - 9_990},
            {"r": "close", "key": "c1", "t": T0 + 20_000, "joined": True, "initiator": "client", "cause": "stale", "player": "p1"},
            {"r": "reconnect", "k": "c1", "key": "c1", "cause": "stale", "closedAt": T0 + 20_000, "outcome": "recovered", "firstSyncAt": T0 + 61_000},
        ]
        with gzip.open(d / "samples" / "lt-client" / "w0.ndjson.gz", "wt") as f:
            f.write("".join(json.dumps(r) + "\n" for r in records))

        result = a.ingest(d)
        self.assertEqual(result["params"]["profile"], "BO75")
        group = result["groups"]["impaired"]
        self.assertEqual(len(group["windows"]), 30 + 60 + 90)
        self.assertEqual({w["segment"] for w in group["windows"]}, set(a.SEGMENTS))
        self.assertEqual(group["windows"][20]["sends"], 1)
        self.assertEqual(group["windows"][0]["joined"], 1)
        self.assertEqual(group["windows"][30 + 20]["joined"], 0)
        self.assertEqual(group["closes"][0]["cause"], "stale")
        self.assertEqual(group["reconnects"][0]["outcome"], "recovered")


if __name__ == "__main__":
    unittest.main()
