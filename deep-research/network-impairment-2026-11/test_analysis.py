#!/usr/bin/env python3
"""Tests for analysis.py on synthetic fixtures: python3 -m unittest test_analysis (stdlib)."""
import gzip
import json
import math
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

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


class HistogramTests(unittest.TestCase):
    def test_pooled_histograms_give_the_same_nearest_rank_percentile(self):
        a_values = [10, 20, 30, 40, 50]
        b_values = [5, 60, 70]
        hists = [a.histogram(a_values), a.histogram(b_values)]
        for p in (50, 90, 99):
            self.assertEqual(a.hist_percentile(hists, p), a.percentile(a_values + b_values, p))
        self.assertIsNone(a.hist_percentile([{}], 99))

    def test_segment_band_is_the_worst_pooled_p99_over_every_offset(self):
        ws = [{"gapHist": a.histogram([v])} for v in (100, 100, 900, 100, 100)]
        self.assertEqual(a.segment_band([ws], 2, "gapHist"), 900)
        self.assertEqual(a.segment_band([ws[:2], ws[3:]], 2, "gapHist"), 100)
        self.assertIsNone(a.segment_band([ws[:1]], 2, "gapHist"), "no segment of that length fits")


class SessionTests(unittest.TestCase):
    def timeline(self):
        return a.Timeline(T0, T0 + 60_000, "BO75")

    def gaps(self, key, start, end, gap=100):
        return [{"r": "update", "k": key, "t": t, "gapMs": gap} for t in range(start, end, gap)]

    def baseline(self, key, gap=100):
        """Updates through the baseline segment (the 30 s before the apply)."""
        return self.gaps(key, T0 - 30_000, T0, gap)

    def test_survivor_rebuilt_and_lost_sessions(self):
        end = T0 + 60_000 + 90_000
        records = [
            # survivor: joined throughout, steady updates
            {"r": "join", "k": "s", "t": T0 - 40_000, "land": "l", "player": "p1"},
            *self.baseline("s"), *self.gaps("s", end - 10_000, end),
            # rebuilt: closed by the server, reconnected with a firstSync
            {"r": "join", "k": "r", "t": T0 - 40_000, "land": "l", "player": "p2"},
            *self.baseline("r"),
            {"r": "close", "key": "r", "t": T0 + 30_000, "joined": True, "initiator": "server", "player": "p2"},
            {"r": "join", "k": "r", "t": T0 + 61_000, "land": "l2", "player": "p2"},
            {"r": "reconnect", "k": "r", "key": "r", "outcome": "recovered", "firstSyncAt": T0 + 61_100, "closedAt": T0 + 30_000},
            *self.gaps("r", end - 10_000, end),
            # lost: closed, reconnect gave up
            {"r": "join", "k": "x", "t": T0 - 40_000, "land": "l", "player": "p3"},
            *self.baseline("x"),
            {"r": "close", "key": "x", "t": T0 + 30_000, "joined": True, "initiator": "server", "player": "p3"},
            {"r": "reconnect", "k": "x", "key": "x", "outcome": "gaveUp", "closedAt": T0 + 30_000},
        ]
        got = a.sessions(records, self.timeline())
        self.assertEqual((got["s"]["closes"], got["s"]["reconnected"], got["s"]["openAtEnd"]), (0, False, True))
        self.assertEqual((got["r"]["reconnected"], got["r"]["rebuilt"], got["r"]["openAtEnd"]), (True, True, True))
        self.assertEqual((got["x"]["rebuilt"], got["x"]["openAtEnd"]), (False, False))
        self.assertEqual((got["s"]["baseGapP99"], got["s"]["lastGapP99"], got["s"]["silentSlots"]), (100, 100, 0))
        self.assertEqual(got["r"]["land"], "l2", "a session's land is its latest join's")
        self.assertEqual(a.session_failures(got["s"], True), [])
        self.assertEqual(a.session_failures(got["r"], True), [])
        self.assertEqual(a.session_failures(got["x"], True), ["not joined at the end", "no gaps at the end"])
        self.assertEqual(a.session_failures(got["s"], False), ["not converged"])

    def test_silent_over_slack_and_no_baseline_sessions_fail(self):
        end = T0 + 60_000 + 90_000
        join = lambda k, t=T0 - 40_000: {"r": "join", "k": k, "t": t, "land": "l", "player": k}
        records = [
            # silent: no update in the last 3 s
            join("quiet"), *self.baseline("quiet"), *self.gaps("quiet", end - 10_000, end - 3_000),
            # over the slack: 100 ms baseline, 250 ms at the end (> 100 + 100)
            join("slow"), *self.baseline("slow"), *self.gaps("slow", end - 10_000, end, 250),
            # within the slack: 100 ms baseline, 200 ms at the end (= 100 + 100)
            join("edge"), *self.baseline("edge"), *self.gaps("edge", end - 10_000, end, 200),
            # no baseline gaps: joined after the baseline
            join("late", T0 + 1_000), *self.gaps("late", end - 10_000, end),
        ]
        got = a.sessions(records, self.timeline())
        self.assertEqual(got["quiet"]["silentSlots"], 3)
        self.assertEqual(a.session_failures(got["quiet"], True), ["silent"])
        self.assertEqual(a.session_failures(got["slow"], True), ["gap over its baseline"])
        self.assertEqual(a.session_failures(got["edge"], True), [], "at its baseline plus one sync interval")
        self.assertEqual(a.session_failures(got["late"], True), ["no baseline gaps"])

    def test_rebuilt_requires_a_first_sync(self):
        s = {"openAtEnd": True, "reconnected": True, "rebuilt": False, "silentSlots": 0, "baseGapP99": 100, "lastGapP99": 100}
        self.assertEqual(a.session_failures(s, True), ["reconnected without a firstSync"])

    def test_a_session_converged_with_its_land_or_its_own_connection(self):
        conv = {"notConverged": [{"land": "bad", "connections": [{"instance": "lt", "key": "k1"}]}]}
        self.assertTrue(a.session_converged({"land": "good"}, "k1", "lt", conv))
        self.assertFalse(a.session_converged({"land": "bad"}, "k1", "lt", conv))
        self.assertTrue(a.session_converged({"land": "bad"}, "k2", "lt", conv), "its own connection converged")
        self.assertTrue(a.session_converged({"land": "bad"}, "k1", "other", conv), "keys are per instance")
        self.assertFalse(a.session_converged({"land": None}, "k1", "lt", conv), "never joined a land")


class ProfileTests(unittest.TestCase):
    def test_counters_are_summed_and_maxima_taken_inside_the_run(self):
        d = pathlib.Path(tempfile.mkdtemp())
        lines = [
            {"ts": T0 - 1, "counters": {"pongTimeoutCloses": 9, "closeFrameTimeouts": 4}},
            {"ts": T0, "counters": {"pongTimeoutCloses": 2, "sendBacklogCloses": 1, "sendBufferedBytesMax": 500}},
            {"ts": T0 + 1_000, "counters": {"pongTimeoutCloses": 3, "sendBufferedBytesMax": 900}},
            {"ts": T0 + 2_000, "counters": {"pongTimeoutCloses": 7}},
        ]
        (d / "profile.jsonl").write_text("".join(json.dumps(x) + "\n" for x in lines))
        got = a.read_profile(d / "profile.jsonl", T0, T0 + 2_000)
        self.assertEqual((got["pongTimeoutCloses"], got["sendBacklogCloses"], got["sendBufferedBytesMax"], got["windows"]), (5, 1, 900, 2))
        self.assertEqual(got["seen"], ["pongTimeoutCloses", "sendBacklogCloses", "sendBufferedBytesMax"],
                         "closeFrameTimeouts appears only outside the range")
        self.assertIsNone(a.read_profile(d / "missing.jsonl", T0, T0 + 1))


class MemoryTests(unittest.TestCase):
    def test_slope(self):
        self.assertAlmostEqual(a.slope_per_s([(0, 100), (1_000, 102), (2_000, 104)]), 2.0)
        self.assertIsNone(a.slope_per_s([(0, 1)]))

    def test_a_file_two_collectors_wrote_fails_clearly(self):
        # Two client instances (M, SR) once wrote one system-metrics.json: two JSON documents.
        d = pathlib.Path(tempfile.mkdtemp())
        one = json.dumps({"system": [{"tsMs": T0, "rssMb": 300}]})
        (d / "system-metrics.json").write_text(one + one)
        with self.assertRaisesRegex(ValueError, "more than one collector"):
            a.read_memory(d, a.Timeline(T0, T0 + 60_000, "P0"))

    def test_the_leak_slope_needs_the_whole_window(self):
        t = a.Timeline(T0, T0 + 60_000, "RATE")
        end = T0 + 150_000

        def slope(samples):
            d = pathlib.Path(tempfile.mkdtemp())
            (d / "system-metrics.json").write_text(json.dumps({"system": [{"tsMs": ts, "rssMb": 300} for ts in samples]}))
            return a.read_memory(d, t)["rssSlopeLast30sMbPerS"]

        full = [end - 30_000 + i * 1_000 for i in range(30)]
        self.assertEqual(slope(full), 0.0)
        self.assertIsNone(slope(full[:3]), "two or three samples at the start: a lost tail (Review S3)")
        self.assertIsNone(slope(full[3:]), "a late first sample")
        self.assertIsNone(slope(full[:10] + full[15:]), "a 6 s gap")
        self.assertEqual(slope(full[:10] + full[14:]), 0.0, "a 5 s gap is allowed")

    def test_peaks_per_segment_and_the_recovery_tail(self):
        d = pathlib.Path(tempfile.mkdtemp())
        t = a.Timeline(T0, T0 + 60_000, "RATE")
        end = T0 + 150_000
        system = [{"tsMs": T0 - 10_000, "rssMb": 100}, {"tsMs": T0 + 10_000, "rssMb": 900}]
        system += [{"tsMs": end - 30_000 + i * 1_000, "rssMb": 300 + i} for i in range(30)]
        (d / "system-metrics.json").write_text(json.dumps({"system": system}))
        ns = lambda est, fin: {"netns": "", "tcpInuse": 0, "tcpTw": 0,
                               "established": {"sendQBytes": est}, "otherStates": {"FIN-WAIT-1": {"sendQBytes": fin}}}
        sock = [
            {"t": T0 + 5_000, "hostTcpMemPages": 4_000, "hostTcpOrphan": 0, "namespaces": [ns(1_000, 500), {"netns": "lt-client", "established": {"sendQBytes": 10**9}, "otherStates": {}}]},
            {"t": T0 - 5_000, "hostTcpMemPages": 50, "hostTcpOrphan": 0, "namespaces": [ns(10, 0)]},
        ]
        (d / "sockstat.jsonl").write_text("".join(json.dumps(x) + "\n" for x in sock))
        m = a.read_memory(d, t)
        self.assertEqual((m["baseline"]["rssPeakMb"], m["impaired"]["rssPeakMb"]), (100, 900))
        self.assertEqual(m["impaired"]["hostTcpMemPeakPages"], 4_000)
        self.assertEqual(m["impaired"]["serverSendQPeakBytes"], 1_500, "the server namespace only, every state")
        self.assertAlmostEqual(m["rssSlopeLast30sMbPerS"], 1.0)
        self.assertEqual(m["rssAtEndMb"], 329)
        self.assertIsNone(a.read_memory(pathlib.Path(tempfile.mkdtemp()), t))


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
        self.assertEqual(group["manifest"], {"files": 1, "joinKeys": 1})
        self.assertEqual(result["expectedProfileWindows"], 180)
        self.assertIsNone(result["serverOnly"], "no lifecycle log: unavailable, not empty")

    def test_a_missing_instance_directory_is_an_empty_manifest(self):
        d = pathlib.Path(tempfile.mkdtemp()) / "run"
        d.mkdir()
        (d / "impairment-timeline.json").write_text(json.dumps(timeline_entries()))
        (d / "run.json").write_text(json.dumps({
            "meta": {}, "params": {"rooms": 1, "population": "U"},
            "groups": {"impaired": {"instance": "lt-clinet", "target": 5, "sendTargetPerS": 5}},
        }))
        self.assertEqual(a.ingest(d)["groups"]["impaired"]["manifest"], {"files": 0, "joinKeys": 0})


def lifecycle(*lines):
    d = pathlib.Path(tempfile.mkdtemp())
    (d / "land-lifecycle.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))
    return d / "land-lifecycle.jsonl"


def joined(sid, player, t, land="hero-defense:l1"):
    return {"event": "sessionJoined", "sessionID": sid, "playerID": player, "landID": land, "instance": 1, "wallMs": t}


def closed(sid, cause, t, code=None):
    return {"event": "sessionClosed", "sessionID": sid, "cause": cause, "code": code, "wallMs": t}


class CloseMatchTests(unittest.TestCase):
    def test_the_log_pairs_joins_and_closes_in_either_order(self):
        log = a.read_lifecycle(lifecycle(
            {"event": "created", "landID": "hero-defense:l1", "instance": 1, "wallMs": T0},
            closed("s1", "pongTimeout", T0 + 10, 1001),
            joined("s1", "g1", T0 + 20),
            joined("s2", "g2", T0 + 5),
        ))
        self.assertEqual(log["s1"]["close"]["cause"], "pongTimeout")
        self.assertEqual(log["s1"]["joins"][0]["playerID"], "g1")
        self.assertIsNone(log["s2"]["close"])
        self.assertIsNone(a.read_lifecycle(pathlib.Path(tempfile.mkdtemp()) / "missing.jsonl"))

    def test_each_client_close_gets_its_connections_server_cause(self):
        log = a.read_lifecycle(lifecycle(
            joined("s1", "g1", T0 - 1_000), closed("s1", "backlogBytes", T0 + 5_000, 4008),
            joined("s2", "g2", T0 + 6_000), closed("s2", "serverClose", T0 + 8_000, 1000),  # c1's reconnect
            joined("s6", "g6", T0 - 1_000), closed("s6", "serverClose", T0 + 100, 1000),  # g6's earlier session
            joined("s6b", "g6", T0 + 20_000),  # g6 joined again: c6 is this one, the closest
            joined("s3", "g3", T0 - 1_000),  # c2: still open
            joined("s4", "g4", T0 - 1_000), closed("s4", "pongTimeout", T0 + 9_000, 1001),  # no client close
            joined("s5", "g5", T0 - 1_000, land="hero-defense:other"), closed("s5", "serverClose", T0, 1000),
        ))
        records = [
            {"r": "join", "k": "c1", "t": T0 - 990, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            {"r": "close", "key": "c1", "t": T0 + 5_010, "joined": True, "initiator": "server", "code": 1006},
            {"r": "join", "k": "c1", "t": T0 + 6_010, "land": "l1", "player": "p1", "serverPlayer": "g2"},
            {"r": "close", "key": "c1", "t": T0 + 8_010, "joined": True, "initiator": "server", "code": 1000},
            {"r": "join", "k": "c5", "t": T0 - 990, "land": "l1", "player": "p5", "serverPlayer": "g5"},  # g5 is in another land
            {"r": "join", "k": "c6", "t": T0 + 20_010, "land": "l1", "player": "p6", "serverPlayer": "g6"},
            {"r": "join", "k": "c2", "t": T0 - 990, "land": "l1", "player": "p2", "serverPlayer": "g3"},
            {"r": "join", "k": "c4", "t": T0 - 990, "land": "l1", "player": "p4", "serverPlayer": "g4"},
            {"r": "join", "k": "c9", "t": T0 - 990, "land": "l1", "player": "p9"},  # no serverPlayer
            {"r": "close", "key": "c9", "t": T0 + 1_000, "joined": True, "initiator": "server", "code": 1006},
        ]
        got = a.match_closes(records, log)
        self.assertEqual(
            [(c["key"], c["sessionID"], c["serverCause"], c["serverCode"]) for c in got["closes"]],
            [("c9", None, None, None), ("c1", "s1", "backlogBytes", 4008), ("c1", "s2", "serverClose", 1000)],
            "in time order; each close to its connection's latest join before it",
        )
        self.assertEqual(got["unmatchedClient"], 1, "c9: no server session")
        self.assertEqual(got["joinsWithoutServerPlayer"], 1, "c9")
        self.assertEqual(got["unmappedJoins"], 1, "c5: g5 joined another land")
        self.assertEqual(got["matchedSessions"], ["s1", "s2"])
        only = a.server_only(log, set(got["matchedSessions"]), T0 - 30_000, T0 + 150_000)
        self.assertEqual([(c["sessionID"], c["cause"]) for c in only],
                         [("s5", "serverClose"), ("s6", "serverClose"), ("s4", "pongTimeout")],
                         "every server-decided close in the run no client close matched, including "
                         "sessions no join of the group maps to (s5, s6)")
        self.assertEqual([c["sessionID"] for c in a.server_only(log, set(got["matchedSessions"]), T0 + 1, T0 + 9_000)],
                         ["s6"], "bounded to [start, end)")

    def test_a_client_close_whose_session_has_no_close_line_is_unmatched(self):
        log = a.read_lifecycle(lifecycle(joined("s1", "g1", T0)))
        records = [
            {"r": "join", "k": "c1", "t": T0 + 10, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            {"r": "close", "key": "c1", "t": T0 + 500, "joined": True, "initiator": "server", "code": 1006},
        ]
        got = a.match_closes(records, log)
        self.assertEqual(got["closes"][0]["sessionID"], "s1")
        self.assertIsNone(got["closes"][0]["serverCause"])
        self.assertEqual(got["unmatchedClient"], 1)

    def test_a_client_side_cause_on_the_server_isnt_server_only(self):
        log = a.read_lifecycle(lifecycle(
            joined("s1", "g1", T0), closed("s1", "connectionLost", T0 + 100),
            joined("s2", "g2", T0), closed("s2", "clientClose", T0 + 100, 1000),
        ))
        records = [
            {"r": "join", "k": "c1", "t": T0, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            {"r": "join", "k": "c2", "t": T0, "land": "l1", "player": "p2", "serverPlayer": "g2"},
        ]
        got = a.match_closes(records, log)
        self.assertEqual(a.server_only(log, set(got["matchedSessions"]), T0, T0 + 1_000), [])

    def test_a_server_error_close_is_server_decided(self):
        log = a.read_lifecycle(lifecycle(joined("s1", "g1", T0), closed("s1", "error", T0 + 100, 1011)))
        self.assertEqual([c["cause"] for c in a.server_only(log, set(), T0, T0 + 1_000)], ["error"],
                         "the server closes on an error, so a client must see it close")


class SegmentWindowTests(unittest.TestCase):
    def test_each_segment_has_its_own_windows_and_sends_count_by_send_time(self):
        d = pathlib.Path(tempfile.mkdtemp()) / "run"
        (d / "samples" / "lt-client").mkdir(parents=True)
        lifted = T0 + 60_500  # an impaired segment of 60.5 s
        (d / "impairment-timeline.json").write_text(json.dumps(timeline_entries(lifted=lifted)))
        (d / "run.json").write_text(json.dumps({
            "meta": {}, "params": {"rooms": 1, "population": "U"},
            "groups": {"impaired": {"instance": "lt-client", "target": 1, "sendTargetPerS": 1}},
        }))
        records = [
            {"r": "join", "k": "c1", "t": T0 - 40_000, "land": "l1", "player": "p1"},
            # Intended in the baseline's last window, sent 0.7 s late, in the impaired segment.
            {"r": "rtt", "k": "c1", "intendedAt": T0 - 500, "sentAt": T0 + 200, "respondedAt": T0 + 210},
            # In the impaired segment's last half second: no impaired window holds it.
            {"r": "update", "k": "c1", "t": lifted - 200, "gapMs": 7},
            # The recovery's first window starts at the lift.
            {"r": "update", "k": "c1", "t": lifted + 100, "gapMs": 9},
            # Cut off by the last phase's end, 1 s before the run's end.
            {"r": "rtt", "k": "c1", "intendedAt": lifted + 89_000, "sentAt": lifted + 89_000, "respondedAt": None, "end": "phaseEnd"},
        ]
        with gzip.open(d / "samples" / "lt-client" / "w0.ndjson.gz", "wt") as f:
            f.write("".join(json.dumps(r) + "\n" for r in records))
        ws = a.ingest(d)["groups"]["impaired"]["windows"]
        by_seg = {s: [w for w in ws if w["segment"] == s] for s in a.SEGMENTS}
        self.assertEqual([len(by_seg[s]) for s in a.SEGMENTS], [30, 60, 90])
        self.assertEqual(by_seg["recovery"][0]["start"], lifted)
        self.assertEqual(by_seg["impaired"][-1]["start"], T0 + 59_000, "the partial window is dropped")
        self.assertEqual(by_seg["recovery"][0]["gapHist"], {"9": 1})
        self.assertFalse(any(w["gapHist"].get("7") for w in ws), "the dropped half second holds it")
        self.assertEqual((by_seg["baseline"][-1]["sends"], by_seg["impaired"][0]["sends"]), (0, 1),
                         "sends by the actual send time")
        self.assertEqual(by_seg["baseline"][-1]["rttP99"], 710, "the RTT by its intended time")
        self.assertEqual(sum(w["unanswered"] for w in ws), 0, "a phaseEnd action in the run's last LATE_MS")


class BoundedEvidenceTests(unittest.TestCase):
    def test_actions_cut_off_by_the_last_phase_arent_unanswered(self):
        end = T0 + 150_000
        rec = lambda at, how: {"r": "rtt", "k": "c1", "intendedAt": at, "sentAt": at, "respondedAt": None, "end": how}
        records = [rec(end - 100, "phaseEnd"), rec(end - a.LATE_MS - 1, "phaseEnd"), rec(end - 50, "closed")]
        ws = a.windows(records, end - 10_000, end, run_end=end)
        self.assertEqual(sum(w.unanswered for w in ws), 2, "the cut-off one isn't, an older one and a closed one are")
        self.assertEqual(sum(w.unanswered for w in a.windows(records, end - 10_000, end)), 3, "without run_end, all count")

    def test_closes_outside_the_run_and_during_a_join(self):
        log = a.read_lifecycle(lifecycle(joined("s1", "g1", T0), closed("s1", "serverClose", T0 + 200_000, 1000)))
        records = [
            {"r": "join", "k": "c1", "t": T0, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            # The teardown close, after the run.
            {"r": "close", "key": "c1", "t": T0 + 200_000, "joined": True, "initiator": "server", "code": 1000},
            {"r": "close", "key": "c2", "t": T0 + 10, "joined": False, "initiator": "client", "code": 1006},
            {"r": "close", "key": "c3", "t": T0 + 20, "joined": False, "initiator": "server", "code": 1011},
            {"r": "close", "key": "c4", "t": T0 + 200_000, "joined": False, "initiator": "server", "code": 1011},
        ]
        got = a.match_closes(records, log, T0 - 30_000, T0 + 150_000)
        self.assertEqual(got["closes"], [], "the teardown close is outside the run")
        self.assertEqual(got["unmatchedClient"], 0)
        self.assertEqual(got["duringJoin"], {"client": 1, "server": 1})
        self.assertEqual(a.match_closes(records, log)["unmatchedClient"], 0, "unbounded, the teardown close matches s1")
        self.assertEqual(len(a.match_closes(records, log)["closes"]), 1)

    def test_a_teardown_join_fails_nothing(self):
        log = a.read_lifecycle(lifecycle(joined("s1", "g1", T0)))
        records = [
            {"r": "join", "k": "c1", "t": T0 - 40_000, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            {"r": "join", "k": "c9", "t": T0 + 151_000, "land": "l1", "player": "p9"},
            {"r": "join", "k": "c8", "t": T0 + 152_000, "land": "l1", "player": "p8", "serverPlayer": "nobody"},
        ]
        got = a.match_closes(records, log, T0 - 30_000, T0 + 150_000)
        self.assertEqual((got["joinsWithoutServerPlayer"], got["unmappedJoins"]), (0, 0))
        early = records + [{"r": "join", "k": "c7", "t": T0 - 50_000, "land": "l1", "player": "p7"}]
        self.assertEqual(a.match_closes(early, log, T0 - 30_000, T0 + 150_000)["joinsWithoutServerPlayer"], 1,
                         "a join before the run still has to name its server player")

    def test_a_reconnect_after_the_run_isnt_a_rebuild(self):
        tl = a.Timeline(T0, T0 + 60_000, "BO75")
        end = tl.segments["recovery"][1]
        records = [
            {"r": "join", "k": "c1", "t": T0 - 40_000, "land": "l1", "player": "p1"},
            {"r": "reconnect", "k": "c1", "key": "c1", "closedAt": end + 1, "outcome": "failed", "firstSyncAt": None},
        ]
        self.assertFalse(a.sessions(records, tl)["c1"]["reconnected"])


class ClientBoundTests(unittest.TestCase):
    def test_a_busy_span_marks_every_window_it_overlaps(self):
        records = [{"r": "loop", "from": T0 + 500, "to": T0 + 1_500, "elu": 0.95, "worker": "w0"},
                   {"r": "loop", "from": T0 + 1_500, "to": T0 + 2_500, "elu": 0.9, "worker": "w0"}]
        ws = a.windows(records, T0, T0 + 4_000)
        self.assertEqual([w.client_bound for w in ws], [True, True, False, False], "0.9 itself is not over the gate")
        w = dict(ws[0].summary(), inputsSent=100, inputsSeen=100, joined=1, sends=10, unanswered=0)
        self.assertEqual(a.health(w, 1, 1, {}), "insufficient", "neither healthy nor unhealthy")
        self.assertEqual(a.health(dict(w, clientBound=False), 1, 1, {}), "healthy")

    def test_the_band_leaves_client_bound_windows_out(self):
        quiet = [dict(rttP99=10, inputP99=10, gapP99=10, clientBound=False) for _ in range(20)]
        hot = [dict(rttP99=500, inputP99=500, gapP99=500, clientBound=True) for _ in range(5)]
        self.assertEqual(a.band([quiet + hot])["rttP99"], 10)
        self.assertEqual(a.band([quiet + [dict(h, clientBound=False) for h in hot]])["rttP99"], 500)

    def test_the_reader_tags_each_loop_record_with_its_worker(self):
        d = pathlib.Path(tempfile.mkdtemp())
        for name in ("w0", "w3"):
            with gzip.open(d / f"{name}.ndjson.gz", "wt") as f:
                f.write(json.dumps({"r": "loop", "from": 0, "to": 1_000, "elu": 0.1}) + "\n")
                f.write(json.dumps({"r": "join", "k": "c", "t": 0, "land": "l1", "player": "p"}) + "\n")
        records = list(a.read_samples(d))
        self.assertEqual(sorted(r["worker"] for r in records if r["r"] == "loop"), ["w0", "w3"])
        self.assertNotIn("worker", [k for r in records if r["r"] == "join" for k in r])
        self.assertEqual(len([r for r in a.in_lands(records, {"other"}) if r["r"] == "loop"]), 2,
                         "a worker's loop records stay with every group of its lands")

    def test_loop_summary_reports_each_workers_largest_span(self):
        spans = [{"r": "loop", "from": 0, "to": 1_000, "elu": 0.3, "worker": "w0"},
                 {"r": "loop", "from": 1_000, "to": 2_000, "elu": 0.6, "worker": "w0"},
                 {"r": "loop", "from": 0, "to": 1_000, "elu": 0.1, "worker": "w1"},
                 {"r": "loop", "from": 5_000, "to": 6_000, "elu": 0.99, "worker": "w1"}]
        got = a.loop_summary(spans, 0, 2_000, ["w0", "w1"])
        self.assertEqual((got["spans"], got["maxEluByWorker"]), (3, {"w0": 0.6, "w1": 0.1}))
        self.assertEqual(got["uncovered"], {}, "w1's 1 s tail gap is within the 2 s allowed")

    def test_every_worker_must_cover_the_run(self):
        tile = lambda w, frm, to: [{"r": "loop", "from": t, "to": t + 1_000, "elu": 0.1, "worker": w} for t in range(frm, to, 1_000)]
        spans = tile("w0", -200, 30_000) + tile("w1", -200, 10_000) + tile("w1", 14_000, 30_000) + tile("w3", -200, 25_000)
        got = a.loop_summary(spans, 0, 30_000, ["w0", "w1", "w2", "w3"])
        self.assertEqual(got["uncovered"], {"w1": "gap 3200 ms from 10800 ms", "w2": "gap 30000 ms from 0 ms",
                                            "w3": "gap 4200 ms from 25800 ms"},
                         "a mid-run gap, a worker with no spans at all, and a sampler that stopped early")
        self.assertEqual(a.loop_summary(tile("w0", 1_500, 30_000), 0, 30_000, ["w0"])["uncovered"], {},
                         "a first span starting 1.5 s in is within the gap")


class OutageSessionTests(unittest.TestCase):
    def test_the_subjects_are_the_sessions_open_at_the_apply(self):
        log = a.read_lifecycle(lifecycle(
            joined("s1", "g1", T0 - 20_000), closed("s1", "serverClose", T0 - 15_000, 1000),
            joined("s1b", "g1b", T0 - 10_000), closed("s1b", "pongTimeout", T0 + 30_000, 1001),
            joined("s2", "g2", T0 + 5_000),
        ))
        records = [
            {"r": "join", "k": "c1", "t": T0 - 20_000, "land": "l1", "player": "p1", "serverPlayer": "g1"},
            {"r": "close", "key": "c1", "t": T0 - 15_000, "joined": True, "initiator": "server", "code": 1000},
            {"r": "reconnect", "k": "c1", "key": "c1", "outcome": "recovered", "firstSyncAt": T0 - 9_900},
            {"r": "join", "k": "c1", "t": T0 - 10_000, "land": "l1", "player": "p1", "serverPlayer": "g1b"},
            {"r": "close", "key": "c1", "t": T0 + 30_000, "joined": True, "initiator": "server", "code": 1006},
            {"r": "reconnect", "k": "c1", "key": "c1", "outcome": "failed", "firstSyncAt": T0 + 40_000},
            {"r": "reconnect", "k": "c1", "key": "c1", "outcome": "recovered", "firstSyncAt": T0 + 62_000},
            {"r": "join", "k": "c2", "t": T0 + 5_000, "land": "l1", "player": "p2", "serverPlayer": "g2"},
        ]
        timeline = a.Timeline(T0, T0 + 60_000, "BO75")
        got = a.outage_sessions(records, log, timeline, a.match_closes(records, log)["sessionsByKey"])
        self.assertEqual(got, [{"key": "c1", "sessionID": "s1b", "serverCause": "pongTimeout", "serverKind": "pongTimeout",
                                "serverCode": 1001, "serverT": T0 + 30_000, "clientCloseCode": 1006, "clientCloseT": T0 + 30_000,
                                "resyncs": [], "recordedResyncs": None, "acksSentWhilePaused": None, "readPausedAt": None,
                                "firstSyncAt": T0 + 62_000}],
                         "c2 joined after the apply; c1's session is its latest join before the apply; its "
                         "firstSync is the first recovered one after the apply, not the earlier or the failed one")

    def paused_reader(self, recorded, early_resync=False):
        """A reader that stopped reading at the apply: the server closes it 13.2 s in (4010), the
        client logs its resync and the close 0.6 and 0.7 s later, when the closed socket drains."""
        log = a.read_lifecycle(lifecycle(joined("s1", "g1", T0 - 20_000), closed("s1", "serverClose", T0 + 13_200, 4010)))
        records = [{"r": "join", "k": "c1", "t": T0 - 20_000, "land": "l1", "player": "p1", "serverPlayer": "g1"}]
        if early_resync:
            records.append({"r": "resync", "k": "c1", "t": T0 - 5_000})
        records += [{"r": "resync", "k": "c1", "t": T0 + 13_800},
                    {"r": "close", "key": "c1", "t": T0 + 13_900, "joined": True, "initiator": "server", "code": 4010,
                     "resyncs": recorded},
                    {"r": "join", "k": "c1", "t": T0 + 14_900, "land": "l1", "player": "p1", "serverPlayer": "g1"},
                    {"r": "resync", "k": "c1", "t": T0 + 24_000}]
        return a.outage_sessions(records, log, a.Timeline(T0, T0 + 25_000, "SR"), a.match_closes(records, log)["sessionsByKey"])

    def test_resyncs_count_on_the_client_side_up_to_the_connections_own_close(self):
        got = self.paused_reader(recorded=1)[0]
        self.assertEqual((got["serverT"], got["resyncs"]), (T0 + 13_200, [T0 + 13_800]),
                         "the resync logged after the server's close, before the client's, counts; the next connection's doesn't")
        got = self.paused_reader(recorded=2, early_resync=True)[0]
        self.assertEqual(got["resyncs"], [T0 + 13_800], "a resync before the apply checks against the record, but isn't the outage's")

    def test_resync_lines_that_disagree_with_the_close_record_are_refused(self):
        with self.assertRaisesRegex(ValueError, "c1: 1 resync lines in the connection open at the apply, its close record counts 2"):
            self.paused_reader(recorded=2)


def synthetic_run(root, run_id, profile, outage=False, conns=50, busy=(), loop_p99=None):
    """A run directory with two groups of ``conns`` connections each: one action, one move event
    and one update per connection per second. With ``outage``, the impaired group goes silent
    during the impaired segment, is closed by the server 30 s in, and reconnects 1 s after the
    lift with a firstSync."""
    d = pathlib.Path(root) / run_id
    lifted = T0 + 60_000
    (d / "impairment-timeline.json").parent.mkdir(parents=True, exist_ok=True)
    loop_ms = {"loopDelayP99Ms": loop_p99} if loop_p99 is not None else {}
    (d / "impairment-timeline.json").write_text(json.dumps(timeline_entries(lifted=lifted, profile=profile)))
    (d / "run.json").write_text(json.dumps({
        "meta": {"git": {"commit": "a" * 40, "dirty": False}}, "params": {"rooms": 10, "population": "M"},
        "groups": {
            "impaired": {"instance": "lt-client", "target": conns, "sendTargetPerS": conns, **loop_ms},
            "healthy-mixed": {"instance": "lt-good", "target": conns, "sendTargetPerS": conns, **loop_ms},
        },
    }))
    start, end = T0 - 30_000, lifted + 90_000
    log = []
    for instance in ("lt-client", "lt-good"):
        silent = outage and instance == "lt-client"
        records = []
        for c in range(conns):
            k = f"{instance}-{c}"
            records.append({"r": "join", "k": k, "t": start - 5_000, "land": "l", "player": k, "serverPlayer": f"g-{k}"})
            log.append(joined(f"s-{k}", f"g-{k}", start - 5_000, land="hero-defense:l"))
            if silent:
                records.append({"r": "close", "key": k, "t": T0 + 30_000, "joined": True, "initiator": "server", "code": 1006, "player": k})
                log.append(closed(f"s-{k}", "pongTimeout", T0 + 30_000 - 5, 1001))
                records.append({"r": "join", "k": k, "t": lifted + 1_000, "land": "l", "player": k, "serverPlayer": f"g2-{k}"})
                log.append(joined(f"s2-{k}", f"g2-{k}", lifted + 1_000, land="hero-defense:l"))
                records.append({"r": "reconnect", "k": k, "key": k, "cause": "server", "closedAt": T0 + 30_000,
                                "outcome": "recovered", "firstSyncAt": lifted + 1_100})
            for t in range(start + c, end, 1_000):
                if silent and T0 <= t < lifted + 1_200:
                    continue
                records.append({"r": "rtt", "k": k, "intendedAt": t, "sentAt": t, "respondedAt": t + 5})
                records.append({"r": "input", "k": k, "sentAt": t, "seenAt": t + 40})
                records.append({"r": "update", "k": k, "t": t + 1, "gapMs": 1_000})
        # One loop span per second (ELU 0.2), busy (0.95) in the ``busy`` seconds, from the
        # healthy instance's worker: the client-bound gate (§ 2).
        for t in range(start - 500, end, 1_000):
            hot = instance == "lt-good" and any(b <= t - T0 < b + 1_000 for b in busy)
            records.append({"r": "loop", "from": t, "to": t + 1_000, "elu": 0.95 if hot else 0.2})
        (d / "samples" / instance).mkdir(parents=True, exist_ok=True)
        with gzip.open(d / "samples" / instance / "w0.ndjson.gz", "wt") as f:
            f.write("".join(json.dumps(r) + "\n" for r in records))
    (d / "land-lifecycle.jsonl").write_text("".join(json.dumps(l) + "\n" for l in log))
    slope = 3.0 if outage else 0.0
    (d / "system-metrics.json").write_text(json.dumps({"system": [
        {"tsMs": t, "rssMb": 200 + slope * (t - start) / 1000} for t in range(start, end, 1_000)]}))
    (d / "profile.jsonl").write_text("".join(
        json.dumps({"ts": t, "counters": {"pongTimeoutCloses": conns if outage and t == T0 + 30_000 else 0, "sendBacklogCloses": 0}}) + "\n"
        for t in range(start, end, 1_000)))
    # Every room converged after recovery (one land, "l").
    (d / "convergence.json").write_text(json.dumps({
        "totals": {"converged": 1, "convergedLate": 0, "mismatched": 0, "missingClients": 0, "inconclusive": 0},
        "startedAt": end, "endedAt": end + 1_000,
        "lands": [{"land": "l", "outcome": "converged", "attempts": 1, "connections": []}]}))
    return a.ingest(d)


class RegenerateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import regenerate
        cls.regenerate = regenerate
        root = tempfile.mkdtemp()
        cls.runs = {f"p0-r{i}": synthetic_run(root, f"p0-r{i}", "P0") for i in (1, 2, 3)}
        cls.runs["bo75-r1"] = synthetic_run(root, "bo75-r1", "BO75", outage=True)

    def test_recovery_row_for_the_outage_and_the_p0_control(self):
        rows = {(p, g): v for _, p, g, v in self.regenerate.recovery_rows(self.runs)}
        # The impaired group is back from the lift + 1.2 s: its first full healthy window starts 2 s in.
        self.assertEqual(rows[("BO75", "impaired")], [2_000])
        self.assertEqual(rows[("BO75", "healthy-mixed")], [0])
        self.assertEqual(rows[("P0", "impaired")], [0, 0, 0], "leave-one-out: quiet runs pass at once")

    def test_session_rows_need_no_control(self):
        # Each session is held to its own baseline: a run alone (the host's 10-room smoke had one
        # BO75 run and no P0) is judged, survivors and rebuilds apart.
        rows = {g: r for rid, _, g, *r in self.regenerate.session_rows({"bo75-r1": self.runs["bo75-r1"]})}
        self.assertEqual(rows["impaired"], [0, 50, 0, None, "pass"])
        self.assertEqual(rows["healthy-mixed"], [50, 0, 0, None, "pass"])

    def test_session_rows_fail_without_the_convergence_check(self):
        run = dict(self.runs["p0-r1"], convergence=None)
        verdicts = {g: r[-1] for rid, _, g, *r in self.regenerate.session_rows({"p0-r1": run})}
        self.assertEqual(verdicts["impaired"], "fail (missing: convergence)")

    def test_session_rows_count_reasons(self):
        run = self.runs["p0-r1"]
        g = run["groups"]["impaired"]
        slow = {k: dict(s, lastGapP99=s["baseGapP99"] + 101) for k, s in list(g["sessions"].items())[:3]}
        broken = dict(run, groups=dict(run["groups"], impaired=dict(g, sessions=dict(g["sessions"], **slow))))
        row = [r for r in self.regenerate.session_rows({"p0-r1": broken}) if r[2] == "impaired"][0]
        self.assertEqual(row[3:], (47, 0, 3, "gap over its baseline 3", "fail"))

    def test_every_p0_repeat_passes_as_its_own_control(self):
        verdicts = {(rid, g): r[-1] for rid, _, g, *r in self.regenerate.session_rows(self.runs) if rid.startswith("p0")}
        self.assertEqual(set(verdicts.values()), {"pass"})

    def test_session_rows_split_survivors_and_rebuilds(self):
        rows = {(rid, g): (s, r, lost) for rid, _, g, s, r, lost, _, _ in self.regenerate.session_rows(self.runs)}
        self.assertEqual(rows[("bo75-r1", "impaired")], (0, 50, 0))
        self.assertEqual(rows[("bo75-r1", "healthy-mixed")], (50, 0, 0))

    def test_close_rows_count_client_and_server_sides(self):
        rows = {r[0]: r for r in self.regenerate.close_rows(self.runs)}
        self.assertEqual(rows["bo75-r1"][2:5], (50, 50, 0))
        self.assertEqual(rows["p0-r1"][6], "pass")

    def test_match_rows_pair_every_close_with_its_cause(self):
        rows = {r[0]: r for r in self.regenerate.match_rows(self.runs)}
        counted = "pongTimeoutCloses +0, sendBacklogCloses +0"
        self.assertEqual(rows["bo75-r1"][2:], (50, 50, 0, 0, 0, "0", "0", "pongTimeout 50", counted, "pass"))
        self.assertEqual(rows["p0-r1"][2:], (0, 0, 0, 0, 0, "0", "0", "–", counted, "pass"))

    def with_server(self, **counters):
        run = self.runs["bo75-r1"]
        return dict(run, server=dict(run["server"], **counters))

    def test_a_counter_above_the_log_is_reported_and_below_it_fails(self):
        above = self.regenerate.match_rows({"x": self.with_server(pongTimeoutCloses=52)})[0]
        self.assertEqual(above[-2:], ("pongTimeoutCloses +2, sendBacklogCloses +0", "pass"),
                         "a counter counts more than the log can (D1): reported, not failed")
        below = self.regenerate.match_rows({"x": self.with_server(pongTimeoutCloses=49)})[0]
        self.assertEqual(below[-1], "fail", "a counter below the log's count is a fault")

    def test_the_stale_rule_fails_on_missing_samples(self):
        run = self.runs["p0-r1"]
        for name, manifest in (("no worker files", {"files": 0, "joinKeys": 0}), ("40 of 50 joins", {"files": 1, "joinKeys": 40})):
            broken = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], manifest=manifest)))
            self.assertTrue(self.regenerate.close_rows({"x": broken})[0][6].startswith("fail (missing: impaired"), name)
            sr = dict(broken, params=dict(broken["params"], profile="SR"))
            self.assertTrue(self.regenerate.close_rows({"x": sr})[0][6].startswith("fail (missing:"), f"SR, {name}")
        bo75 = dict(run, params=dict(run["params"], profile="BO75"),
                    groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], manifest={"files": 0, "joinKeys": 0})))
        self.assertEqual(self.regenerate.close_rows({"x": bo75})[0][6], "reported", "characterisation profiles stay reported")

    def test_a_counter_the_profile_never_carries_is_missing(self):
        run = self.runs["bo75-r1"]
        self.assertIn("pongTimeoutCloses", run["server"]["seen"])
        old_build = self.with_server(seen=["pongTimeoutCloses"])
        row = self.regenerate.match_rows({"x": old_build})[0]
        self.assertEqual((row[-2], row[-1]), ("–", "fail (missing: profile)"),
                         "no sendBacklogCloses in any line: not measured, not 0")

    def test_criterion_2_fails_on_every_missing_input(self):
        run = self.runs["bo75-r1"]
        no_log = dict(run, sessionCloseCauses=None, serverOnly=None)
        no_profile = dict(run, server=None)
        thin_profile = self.with_server(windows=10)
        lost_worker = dict(run, groups=dict(run["groups"], impaired=dict(
            run["groups"]["impaired"], manifest={"files": 0, "joinKeys": 0})))
        for name, broken, reason in (("no lifecycle log", no_log, "lifecycle log"),
                                     ("no profile", no_profile, "profile"),
                                     ("10 of 180 windows", thin_profile, "profile"),
                                     ("no expected window count (an older result)",
                                      {k: v for k, v in run.items() if k != "expectedProfileWindows"}, "profile"),
                                     ("lost worker file", lost_worker, "impaired samples")):
            row = self.regenerate.match_rows({"x": broken})
            self.assertEqual(len(row), 1, f"{name}: the run still has a row")
            self.assertTrue(row[0][-1].startswith("fail (missing:") and reason in row[0][-1], (name, row[0][-1]))

    def test_criterion_2_fails_on_a_server_only_close_or_an_unmapped_join(self):
        run = self.runs["p0-r1"]
        only = dict(run, serverOnly=[{"sessionID": "s9", "cause": "pongTimeout", "code": None, "t": T0}])
        self.assertEqual(self.regenerate.match_rows({"x": only})[0][5:], (1, 0, "0", "0", "–", "pongTimeoutCloses +0, sendBacklogCloses +0", "fail"))

    def test_closes_during_a_join_match_by_code(self):
        run = self.runs["p0-r1"]
        unjoined = {"sessionID": "u1", "cause": "serverClose", "code": 1013, "t": T0 + 5}

        def with_join(codes, server, client_initiated=None, t=T0):
            during = [{"t": t, "code": int(code)} for code, n in sorted(codes.items()) for _ in range(n)]
            cm = dict(run["groups"]["impaired"]["closeMatch"], duringJoinServer=during,
                      duringJoin=client_initiated if client_initiated is not None else {"server": sum(codes.values())})
            group = dict(run["groups"]["impaired"], closeMatch=cm)
            return dict(run, groups=dict(run["groups"], impaired=group), unjoinedServerCloses=server,
                        serverOnly=list(run["serverOnly"]) + [dict(c) for c in server])

        row = self.regenerate.match_rows({"x": with_join({"1013": 1}, [unjoined])})[0]
        self.assertEqual((row[4], row[5], row[7], row[-1]), (0, 0, "1 (serverClose 1)", "pass"),
                         "a server close during a join with its server cause is matched")
        self.assertEqual(row[8], "1013 ×1")
        twice = [unjoined, dict(unjoined, sessionID="u2"), dict(unjoined, sessionID="u3", code=1011)]
        row = self.regenerate.match_rows({"x": with_join({"1013": 2, "1011": 1}, twice)})[0]
        self.assertEqual((row[8], row[-1]), ("1011 ×1, 1013 ×2; 2 ambiguous", "pending (2 ambiguous pairs)"),
                         "a repeated code shows, and the verdict isn't final")
        row = self.regenerate.match_rows({"x": with_join({"1013": 1}, [])})[0]
        self.assertEqual((row[4], row[-1]), (1, "fail"), "a client one without the server's line")
        row = self.regenerate.match_rows({"x": with_join({}, [unjoined])})[0]
        self.assertEqual((row[5], row[-1]), (1, "fail"), "a server one no client saw")
        row = self.regenerate.match_rows({"x": with_join({"1011": 1}, [unjoined])})[0]
        self.assertEqual((row[4], row[5], row[-1]), (1, 1, "fail"), "different codes don't pair")
        row = self.regenerate.match_rows({"x": with_join({}, [], {"client": 4})})[0]
        self.assertEqual(row[-1], "pass", "a client's own join timeouts aren't server closes")
        # Time: a client close 95 s away from the server's line doesn't pair (Review S1).
        row = self.regenerate.match_rows({"x": with_join({"1013": 1}, [unjoined], t=T0 + 95_000)})[0]
        self.assertEqual((row[4], row[5], row[-1]), (1, 1, "fail"), "same code, far apart")
        row = self.regenerate.match_rows({"x": with_join({"1013": 1}, [unjoined], t=T0 + 5_005)})[0]
        self.assertEqual(row[-1], "pass", "within the 5 s tolerance")
        self.assertIn("2 ambiguous", self.regenerate.match_rows({"x": with_join({"1013": 2}, twice)})[0][8])
        self.assertEqual(self.regenerate.match_rows({"x": with_join({"1013": 3}, twice)})[0][-1], "fail",
                         "a failure still wins over pending")
        # A JoinResponse that crossed the close: the server session joined, but no client join
        # maps to it, so it is in serverOnly, not in the never-joined list (Review S2).
        crossed = dict(run, groups=with_join({"1013": 1}, [])["groups"],
                       serverOnly=list(run["serverOnly"]) + [{"sessionID": "j1", "cause": "pongTimeout", "code": 1013, "t": T0 + 40}])
        row = self.regenerate.match_rows({"x": crossed})[0]
        self.assertEqual((row[4], row[5], row[8], row[-1]), (0, 0, "0", "pass"))

    def test_pair_by_code_is_one_to_one_in_time_order(self):
        c = [{"t": 0, "code": 1}, {"t": 10_000, "code": 1}, {"t": 20_000, "code": 2}]
        s = [{"t": 1_000, "code": 1}, {"t": 30_000, "code": 1}, {"t": 21_000, "code": 2}]
        got = a.pair_by_code(c, s)
        self.assertEqual((got["paired"], [x["t"] for x in got["client"]], [x["t"] for x in got["server"]]),
                         (2, [10_000], [30_000]))
        got = a.pair_by_code([{"t": 0, "code": 1}], [{"t": 100, "code": 1}, {"t": 200, "code": 1}])
        self.assertEqual((got["paired"], len(got["server"]), got["ambiguous"]), (1, 1, 1), "one server line stays unmatched")

    def test_quiet_profiles_fail_on_any_server_close(self):
        run = self.runs["p0-r1"]
        rows = {r[0]: r for r in self.regenerate.quiet_rows(self.runs)}
        self.assertEqual(rows["p0-r1"][2:], (0, 0, 0, "pass"))
        self.assertNotIn("bo75-r1", rows, "BO75 has its own criteria")
        joining = dict(run, sessionCloseCauses={"serverClose": 1})
        self.assertEqual(self.regenerate.quiet_rows({"x": joining})[0][-1], "fail", "a server close of a joining session")
        cm = dict(run["groups"]["impaired"]["closeMatch"], duringJoin={"server": 1})
        seen = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], closeMatch=cm)))
        self.assertEqual(self.regenerate.quiet_rows({"x": seen})[0][3:], (1, 0, "fail"), "one a client saw during a join")
        quiet_close = dict(run, sessionCloseCauses={"clientClose": 3, "connectionLost": 1})
        self.assertEqual(self.regenerate.quiet_rows({"x": quiet_close})[0][-1], "pass", "client and lost closes aren't server-decided")
        windows = run["groups"]["impaired"]["windows"]
        first_recovery = next(i for i, w in enumerate(windows) if w["segment"] == "recovery")
        first_impaired = next(i for i, w in enumerate(windows) if w["segment"] == "impaired")
        def unanswered_at(i):
            ws = [dict(w, unanswered=1) if j == i else w for j, w in enumerate(windows)]
            return dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], windows=ws)))
        self.assertEqual(self.regenerate.quiet_rows({"x": unanswered_at(first_recovery)})[0][4:], (1, "fail"))
        self.assertEqual(self.regenerate.quiet_rows({"x": unanswered_at(first_impaired)})[0][4:], (0, "pass"),
                         "the impaired segment's own unanswered are allowed")
        l1 = dict(run, params=dict(run["params"], profile="L1"))
        self.assertEqual(self.regenerate.quiet_rows({"x": l1})[0][4], "not required")
        self.assertEqual(self.regenerate.quiet_rows({"x": dict(run, sessionCloseCauses=None)})[0][-1],
                         "fail (missing: lifecycle log)")
        group = dict(run["groups"]["impaired"], closeMatch=dict(run["groups"]["impaired"]["closeMatch"], joinsWithoutServerPlayer=3))
        unmapped = dict(run, groups=dict(run["groups"], impaired=group))
        self.assertEqual(self.regenerate.match_rows({"x": unmapped})[0][6], 3)
        self.assertEqual(self.regenerate.match_rows({"x": unmapped})[0][-1], "fail")

    def test_a_group_short_of_its_target_or_without_a_send_target_fails(self):
        run = self.runs["bo75-r1"]
        short = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], manifest={"files": 1, "joinKeys": 40})))
        no_send = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], sendTargetPerS=None)))
        zero_send = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], sendTargetPerS=0)))
        for name, broken, reason in (("40 of 50 joins", short, "impaired joins 40/50"),
                                     ("no sendTargetPerS", no_send, "impaired sendTargetPerS"),
                                     ("sendTargetPerS 0", zero_send, "impaired sendTargetPerS")):
            runs = dict(self.runs, **{"bo75-r1": broken})
            recovery = {(p, g): v for _, p, g, v in self.regenerate.recovery_rows(runs)}
            self.assertEqual(recovery[("BO75", "impaired")], [f"fail (missing: {reason})"], name)
            sessions = {(rid, g): r[-1] for rid, _, g, *r in self.regenerate.session_rows(runs)}
            self.assertEqual(sessions[("bo75-r1", "impaired")], f"fail (missing: {reason})", name)

    def test_sr_is_judged_against_ms_p0_and_fails_without_it(self):
        sr = dict(self.runs["bo75-r1"], params=dict(self.runs["bo75-r1"]["params"], population="SR", profile="SR"))
        with_m = dict(self.runs, **{"sr-r1": sr})
        recovery = {(p, g): v for (_, pop), p, g, v in self.regenerate.recovery_rows(with_m) if pop == "SR"}
        self.assertEqual(recovery[("SR", "impaired")], [2_000], "M's P0 repeats are SR's control")
        sessions = {g: r for rid, _, g, *r in self.regenerate.session_rows(with_m) if rid == "sr-r1"}
        self.assertEqual(sessions["impaired"][-1], "pass")
        alone = {"sr-r1": sr}
        self.assertEqual([v for *_, v in self.regenerate.recovery_rows(alone)][0], ["fail (no control)"])
        sessions = {g: r for rid, _, g, *r in self.regenerate.session_rows(alone)}
        self.assertEqual(sessions["impaired"][-1], "pass", "per-session recovery needs no control")

    def with_subjects(self, run, change, group="impaired"):
        g = run["groups"][group]
        return dict(run, groups=dict(run["groups"], **{group: dict(g, outageSessions=[change(dict(s)) for s in g["outageSessions"]])}))

    def test_bo75_every_session_open_at_the_apply_is_closed_and_rebuilt(self):
        rows = {(r[0], r[2]): r[3:] for r in self.regenerate.profile_rows(self.runs)}
        self.assertEqual(rows[("bo75-r1", "impaired")][:4], (50, 50, 50, 0))
        self.assertEqual(rows[("bo75-r1", "impaired")][-1], "pass")
        self.assertIn("pongTimeout 50", rows[("bo75-r1", "impaired")][4])
        self.assertNotIn(("bo75-r1", "healthy-mixed"), rows, "healthy groups are judged by isolation")
        self.assertFalse(any(rid.startswith("p0") for rid, _ in rows), "only BO75 and SR have these criteria")
        subjects = self.runs["bo75-r1"]["groups"]["impaired"]["outageSessions"]
        self.assertEqual(subjects[0]["serverCause"], "pongTimeout")
        self.assertEqual(subjects[0]["firstSyncAt"], T0 + 60_000 + 1_100)

    def test_bo75_fails_on_a_wrong_cause_a_late_rebuild_or_a_stale_close_without_pong(self):
        run = self.runs["bo75-r1"]
        lifted = run["timeline"]["liftedAt"]
        def client_close(s):
            s["serverCause"] = s["serverKind"] = "clientClose"
            return s
        def client_got_4011(s):
            s["serverCause"], s["serverKind"], s["serverCode"] = "serverClose", "unresponsive", 4011
            s["clientCloseCode"] = 4011
            return s
        def after_lift(s):
            s["serverT"] = lifted + 1_000
            return s
        def late(s):
            s["firstSyncAt"] = lifted + 60_001
            return s
        def never(s):
            s["firstSyncAt"] = None
            return s
        def after_recovery(s):
            s["serverT"] = lifted + a.RECOVERY_MS
            return s
        for name, broken in (("closed as a client close", self.with_subjects(run, client_close)),
                             ("the client got the 4011 (no auto-rejoin)", self.with_subjects(run, client_got_4011)),
                             ("closed after the lift, not inside the outage", self.with_subjects(run, after_lift)),
                             ("rebuilt 60.001 s after the lift", self.with_subjects(run, late)),
                             ("never rebuilt", self.with_subjects(run, never)),
                             ("closed after recovery", self.with_subjects(run, after_recovery))):
            self.assertEqual(self.regenerate.profile_rows({"x": broken})[0][-1], "fail", name)
        g = run["groups"]["healthy-mixed"]
        stale = dict(g["closeMatch"], closes=[{"key": "h", "t": T0, "code": 1000, "cause": "stale", "sessionID": "s",
                                                "serverCause": "clientClose", "serverKind": "clientClose", "serverCode": 1000, "serverT": T0}])
        broken = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(g, closeMatch=stale)}))
        row = self.regenerate.profile_rows({"x": broken})[0]
        self.assertEqual((row[-3], row[-1]), (1, "fail"),
                         "a stale close anywhere in a BO75 run must match a pong, backlog or 4011 close")
        matched_4011 = dict(stale, closes=[dict(stale["closes"][0], serverCause="serverClose", serverKind="unresponsive", serverCode=4011)])
        broken = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(g, closeMatch=matched_4011)}))
        self.assertEqual(self.regenerate.profile_rows({"x": broken})[0][-3], 0, "the stale rule matches 4011")
        late = dict(stale, closes=[dict(stale["closes"][0], serverCause="pongTimeout", serverKind="pongTimeout",
                                        serverT=run["timeline"]["liftedAt"] + a.RECOVERY_MS)])
        broken = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(g, closeMatch=late)}))
        row = self.regenerate.profile_rows({"x": broken})[0]
        self.assertEqual((row[-3], row[-1]), (1, "fail"), "matched only after recovery")

    def test_bo75_4011_inside_the_outage_passes(self):
        run = self.runs["bo75-r1"]
        applied = run["timeline"]["appliedAt"]
        def unresponsive(s):
            s["serverCause"], s["serverKind"], s["serverCode"], s["serverT"] = "serverClose", "unresponsive", 4011, applied + 9_500
            s["clientCloseCode"] = 1006
            return s
        row = self.regenerate.profile_rows({"x": self.with_subjects(run, unresponsive)})[0]
        self.assertEqual(row[-1], "pass", "4011 about 9.5 s into the blackout, the client saw an abnormal close")
        self.assertIn("unresponsive 50", row[-2])

    def test_the_per_profile_criteria_fail_on_missing_inputs(self):
        run = self.runs["bo75-r1"]
        no_log = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], outageSessions=None)))
        self.assertEqual(self.regenerate.profile_rows({"x": no_log})[0][-1], "fail (missing: lifecycle log)")
        short = dict(run, groups=dict(run["groups"], impaired=dict(
            run["groups"]["impaired"], outageSessions=run["groups"]["impaired"]["outageSessions"][:49])))
        self.assertEqual(self.regenerate.profile_rows({"x": short})[0][-1], "fail (49/50 open at the apply)")

    def test_sr_needs_one_resync_then_4010_acks_while_paused_and_a_rebuild_by_the_end(self):
        base = self.runs["bo75-r1"]
        sr = dict(base, params=dict(base["params"], population="SR", profile="SR"))
        applied, lifted = base["timeline"]["appliedAt"], base["timeline"]["liftedAt"]
        def slow_consumer(s, resyncs=1, acks=13):
            s["serverCause"], s["serverKind"], s["serverCode"], s["serverT"] = "serverClose", "slowConsumer", 4010, applied + 13_200
            s["resyncs"] = [applied + 3_100 + n for n in range(resyncs)]
            s["acksSentWhilePaused"] = acks
            s["firstSyncAt"] = lifted + 80_000
            return s
        row = self.regenerate.profile_rows({"x": self.with_subjects(sr, slow_consumer)})[0]
        self.assertEqual(row[-1], "pass", "one resync, a 4010, acks while paused, a firstSync within the recovery segment")
        self.assertIn("resyncs per reader {1: 50}", row[-2])
        self.assertEqual(self.regenerate.profile_rows({"x": sr})[0][-1].split(" ")[0], "fail", "a pong timeout is not 4010")
        two = self.regenerate.profile_rows({"x": self.with_subjects(sr, lambda s: slow_consumer(s, resyncs=2))})[0]
        self.assertEqual(two[-1], "fail", "two resyncs before the 4010")
        no_acks = self.regenerate.profile_rows({"x": self.with_subjects(sr, lambda s: slow_consumer(s, acks=0))})[0]
        self.assertRegex(no_acks[-1], r"fail \(missing: precondition: 50 slow reader\(s\) sent no acks while paused\)")
        def backlog(s):
            slow_consumer(s)
            s["serverCause"] = s["serverKind"] = "backlogUnwritable"
            return s
        row = self.regenerate.profile_rows({"x": self.with_subjects(sr, backlog)})[0]
        self.assertEqual(row[-1], "fail", "a 4008 instead of the 4010")
        self.assertIn("4008 (if seen): 50", row[-2])

    # --- sync-lag tracking (#332) ---------------------------------------------------------

    def tracked(self, run, profile=None, resyncs=0, server_resyncs=None, alongside=0, kinds=None, slow=0, unresponsive=0, reset_bytes=0):
        """``run`` with sync-lag counters in its profile, ``resyncs`` client resync lines in its
        impaired group, and lifecycle close kinds."""
        server = dict(run["server"], seen=sorted(set(run["server"].get("seen") or []) | set(a.SYNC_LAG_SUMS)),
                      **{k: 0 for k in a.SYNC_LAG_SUMS})
        server.update(syncLagResyncs=resyncs if server_resyncs is None else server_resyncs, syncLagResyncsAlongside=alongside,
                      syncLagSlowConsumerCloses=slow, syncLagUnresponsiveCloses=unresponsive, syncLagKeyScopeResetBytes=reset_bytes)
        g = run["groups"]["impaired"]
        lines = [{"key": f"k{i}", "t": run["timeline"]["appliedAt"] + 1_000 + i} for i in range(resyncs)]
        out = dict(run, server=server, groups=dict(run["groups"], impaired=dict(g, resyncs=lines)),
                   sessionCloseKinds=dict(kinds or {}, slowConsumer=slow, unresponsive=unresponsive))
        if profile:
            out["params"] = dict(run["params"], profile=profile)
        return out

    def with_recovery(self, run, reconnects=True, **window):
        """``run`` with its impaired group's recovery windows changed by ``window``, its
        reconnects kept or dropped."""
        g = run["groups"]["impaired"]
        ws = [dict(w, **window) if w["segment"] == "recovery" else w for w in g["windows"]]
        return dict(run, groups=dict(run["groups"], impaired=dict(g, windows=ws, reconnects=g["reconnects"] if reconnects else [])))

    def test_a_recovery_without_enough_inputs_is_insufficient_not_not_recovered(self):
        r = self.regenerate
        rows = lambda run: {(p, g): v for _, p, g, v in r.recovery_rows(dict(self.runs, **{"bo75-r1": run}))}
        bo75 = self.runs["bo75-r1"]
        self.assertTrue(bo75["groups"]["impaired"]["reconnects"], "the fixture's impaired group reconnects")
        with mock.patch.object(r, "before_reconnect_fix", return_value=True):
            # Fully joined, no inputs from the reconnected sessions (#422): unmeasured, with the cause.
            silent = self.with_recovery(bo75, inputsSent=0, inputsSeen=0, sends=0)
            self.assertEqual(rows(silent)[("BO75", "impaired")], [r.NO_INPUTS_RECONNECTED])
            # Sends below the 95 % share (only the sessions that never reconnected still send).
            short = self.with_recovery(bo75, sends=1)
            self.assertEqual(rows(short)[("BO75", "impaired")], [r.NO_INPUTS_RECONNECTED])
            # The same without reconnects: too few inputs, no known cause.
            self.assertEqual(rows(self.with_recovery(bo75, reconnects=False, inputsSent=0, inputsSeen=0, sends=0))[("BO75", "impaired")],
                             [r.NO_INPUTS])
            # Sessions missing, not silent (never fully joined): not recovered, whatever was sent.
            missing = self.with_recovery(bo75, joined=0, inputsSent=0, inputsSeen=0, sends=0)
            self.assertEqual(rows(missing)[("BO75", "impaired")], [None])
            # Loaded windows that miss the band: "not recovered" (None).
            late = self.with_recovery(bo75, rttP99=10_000)
            self.assertEqual(rows(late)[("BO75", "impaired")], [None])
            self.assertIn("not recovered", r.fmt_recovery([None]))
            # Loaded windows, but never RECOVERY_RUN in a row: still can't be judged.
            g = bo75["groups"]["impaired"]
            rec_i = [i for i, w in enumerate(g["windows"]) if w["segment"] == "recovery"]
            ws = [dict(w, sends=0) if i in rec_i and rec_i.index(i) % a.RECOVERY_RUN == a.RECOVERY_RUN - 1 else w
                  for i, w in enumerate(g["windows"])]
            broken = dict(bo75, groups=dict(bo75["groups"], impaired=dict(g, windows=ws)))
            self.assertEqual(rows(broken)[("BO75", "impaired")], [r.NO_INPUTS_RECONNECTED])
        # #422's label only for a run measured before its fix; after it, or when git can't tell, the generic one.
        for before in (False, None):
            with self.subTest(before=before), mock.patch.object(r, "before_reconnect_fix", return_value=before):
                self.assertEqual(rows(silent)[("BO75", "impaired")], [r.NO_INPUTS])

    def test_before_the_reconnect_fix_is_read_from_git_ancestry(self):
        r = self.regenerate
        # The published set's commit predates f90471d4; f90471d4 itself has the fix; an unknown commit can't be told.
        self.assertIs(r.before_reconnect_fix("d8321fde724be328614394b28fe4c9846f1d04a4"), True)
        self.assertIs(r.before_reconnect_fix("f90471d4f65364e89f40ca613e449f2ba05314ce"), False)
        self.assertIsNone(r.before_reconnect_fix("a" * 40))
        self.assertIsNone(r.before_reconnect_fix(None))

    def test_a_shallow_clone_cant_tell_before_from_after_the_fix(self):
        # There, --is-ancestor reads a fix commit it doesn't have as "not an ancestor": a post-fix
        # run would read as pre-fix. git rev-parse --is-shallow-repository says "true": None.
        r = self.regenerate
        real = subprocess.run

        def shallow(args, **kw):
            if args[:3] == ["git", "rev-parse", "--is-shallow-repository"]:
                return subprocess.CompletedProcess(args, 0, stdout="true\n", stderr="")
            return real(args, **kw)
        r.before_reconnect_fix.cache_clear()
        self.addCleanup(r.before_reconnect_fix.cache_clear)
        with mock.patch.object(r.subprocess, "run", side_effect=shallow):
            self.assertIsNone(r.before_reconnect_fix("d8321fde724be328614394b28fe4c9846f1d04a4"))
            self.assertIsNone(r.before_reconnect_fix("f90471d4f65364e89f40ca613e449f2ba05314ce"))
        r.before_reconnect_fix.cache_clear()
        self.assertIs(r.before_reconnect_fix("d8321fde724be328614394b28fe4c9846f1d04a4"), True, "a full clone still tells")

    def test_the_results_lead_in_names_the_unmeasured_rows_only_when_there_are_some(self):
        r = self.regenerate
        silent = self.with_recovery(self.runs["bo75-r1"], inputsSent=0, inputsSeen=0, sends=0)
        with mock.patch.object(r, "before_reconnect_fix", return_value=True):
            text = r.tables(dict(self.runs, **{"bo75-r1": silent}))
        self.assertIn("**Unmeasured rows.**", text)
        self.assertIn("Measured before f90471d4: reconnected sessions sent no inputs in ws-loadtest's spread and event send modes (#422)", text)
        self.assertIn("the recovery sends, RTT samples, unanswered counts and upstream bytes after its reconnects", text)
        self.assertIn(": M BO75 impaired. Measured, at reduced room input load: M BO75 healthy-mixed. ", text)
        self.assertIn("Not affected: per-session recovery", text)
        self.assertNotIn("Unmeasured rows", r.tables(self.runs))
        # A run at or after the fix gets the generic label, and no lead-in.
        with mock.patch.object(r, "before_reconnect_fix", return_value=False):
            self.assertNotIn("Unmeasured rows", r.tables(dict(self.runs, **{"bo75-r1": silent})))

    def test_rate_resyncs_missing_at_a_close_are_in_flight_up_to_the_sessions_closed(self):
        r = self.regenerate
        rate = lambda closes, **kw: dict(self.tracked(self.runs["bo75-r1"], profile="RATE", **kw), sessionCloseCauses=closes)
        self.assertEqual(r.sync_lag_rows({"x": rate({"serverClose": 2, "connectionLost": 1}, resyncs=5, server_resyncs=8)})[0][-1],
                         "in flight at close: 3 of at most 3 (server 8 − clients 5; at most one unacked resync per closed "
                         "session; totals, not attributable per connection)")
        # Any close drops what is queued behind it: connectionLost alone is enough.
        self.assertTrue(r.sync_lag_rows({"x": rate({"connectionLost": 4}, resyncs=5, server_resyncs=8)})[0][-1].startswith("in flight at close: 3 of at most 4"))
        # More missing than sessions closed: at most one unacked resync each, so a fail.
        self.assertEqual(r.sync_lag_rows({"x": rate({"serverClose": 2}, resyncs=5, server_resyncs=8, slow=2)})[0][-1],
                         "fail (resyncs: clients 5, server 8: 3 missing, more than the 2 sessions closed (at most one unacked resync each))")
        for name, run in (("no close", rate({}, resyncs=5, server_resyncs=8)),
                          ("more clients' than the server's", rate({"serverClose": 2}, resyncs=8, server_resyncs=5, slow=2)),
                          ("not a throttle profile", dict(self.tracked(self.runs["bo75-r1"], resyncs=5, server_resyncs=8, slow=2),
                                                         sessionCloseCauses={"serverClose": 5}))):
            with self.subTest(name):
                self.assertTrue(r.sync_lag_rows({"x": run})[0][-1].startswith("fail (resyncs: clients"), name)

    def test_close_kinds_split_server_closes_by_sync_lag_code(self):
        self.assertEqual(a.close_kind("serverClose", 4010), "slowConsumer")
        self.assertEqual(a.close_kind("serverClose", 4011), "unresponsive")
        self.assertEqual(a.close_kind("serverClose", 4000), "serverClose")
        self.assertEqual(a.close_kind("backlogUnwritable", 4008), "backlogUnwritable", "4008 keeps its own causes")
        self.assertEqual(a.close_kind("pongTimeout", 1001), "pongTimeout")

    def test_sync_lag_counters_are_required(self):
        row = self.regenerate.sync_lag_rows({"x": self.runs["p0-r1"]})[0]
        self.assertRegex(row[-1], r"fail \(missing: sync-lag counters \(syncLagResyncs, ")

    def test_p0_allows_no_resync_and_no_4008_4010_or_4011(self):
        p0 = self.runs["p0-r1"]
        self.assertEqual(self.regenerate.sync_lag_rows({"x": self.tracked(p0)})[0][-1], "pass")
        for name, run in (("a resync", self.tracked(p0, resyncs=1)),
                          ("a 4010", self.tracked(p0, slow=1)),
                          ("a 4011", self.tracked(p0, unresponsive=1)),
                          ("a 4008", self.tracked(p0, kinds={"backlogUnwritable": 1}))):
            self.assertEqual(self.regenerate.sync_lag_rows({"x": run})[0][-1], "fail", name)

    def test_a_resync_in_d50j10_or_l5_is_a_finding(self):
        for profile in ("D50J10", "L5"):
            run = self.tracked(self.runs["p0-r1"], profile=profile, resyncs=2)
            self.assertEqual(self.regenerate.sync_lag_rows({"x": run})[0][-1], "finding (2 resyncs)", profile)

    def test_the_clients_resyncs_and_the_close_codes_must_match_the_server(self):
        run = self.tracked(self.runs["bo75-r1"], resyncs=3, server_resyncs=2, alongside=1, unresponsive=4, reset_bytes=777)
        row = self.regenerate.sync_lag_rows({"x": run})[0]
        self.assertEqual(row[2:], (3, 3, 0, 0, 4, 0, 0, 777, "pass"), "resyncs plus alongside equal the clients'")
        off = dict(run, server=dict(run["server"], syncLagResyncsAlongside=0, syncLagUnresponsiveCloses=3))
        self.assertEqual(self.regenerate.sync_lag_rows({"x": off})[0][-1],
                         "fail (resyncs: clients 3, server 2; 4011: log 4, counter 3)")

    def test_a_4012_fails_p0_and_is_a_finding_elsewhere_and_is_cross_checked(self):
        def with_4012(run, closes=1, counter=1, failures=3):
            out = dict(run, sessionCloseKinds=dict(run["sessionCloseKinds"], unencodableView=closes))
            out["server"] = dict(run["server"], syncLagUnencodableCloses=counter, syncLagSnapshotEncodeFailures=failures)
            return out
        self.assertEqual(a.close_kind("serverClose", 4012), "unencodableView")
        self.assertEqual(self.regenerate.sync_lag_rows({"x": with_4012(self.tracked(self.runs["p0-r1"]))})[0][-1], "fail")
        for profile in ("BO75", "SR", "COMBO", "RATE"):
            row = self.regenerate.sync_lag_rows({"x": with_4012(self.tracked(self.runs["bo75-r1"], profile=profile))})[0]
            self.assertEqual(row[-1], "finding (1 × 4012)", profile)
            self.assertEqual(row[7:9], (1, 3))
        both = with_4012(self.tracked(self.runs["p0-r1"], profile="L5", resyncs=2))
        self.assertEqual(self.regenerate.sync_lag_rows({"x": both})[0][-1], "finding (1 × 4012, 2 resyncs)")
        off = with_4012(self.tracked(self.runs["bo75-r1"]), counter=0)
        self.assertEqual(self.regenerate.sync_lag_rows({"x": off})[0][-1], "fail (4012: log 1, counter 0)")
        few = with_4012(self.tracked(self.runs["bo75-r1"]), failures=2)
        self.assertEqual(self.regenerate.sync_lag_rows({"x": few})[0][-1], "fail (4012: 1 close(s) but 2 failed snapshot encodes)")
        combo = self.combo()
        g = combo["groups"]["impaired"]
        applied = combo["timeline"]["appliedAt"]
        closed = self.combo(closeMatch=dict(g["closeMatch"], closes=[{"key": "k1", "t": applied + 5_000, "serverKind": "unencodableView"}]))
        self.assertIn("4012 ×1", self.regenerate.rate_rows({"x": closed})[0][-2])

    def test_sr_healthy_sessions_are_gated_and_combo_reported(self):
        base = self.runs["bo75-r1"]
        sr = dict(base, params=dict(base["params"], profile="SR"))
        rows = {r[2]: r for r in self.regenerate.healthy_rows({"x": sr})}
        self.assertEqual(rows["healthy-mixed"][3:], (50, 0, 0, "pass"))
        g = sr["groups"]["healthy-mixed"]
        resynced = dict(sr, groups=dict(sr["groups"], **{"healthy-mixed": dict(g, resyncs=[{"key": "h1", "t": T0}])}))
        self.assertEqual({r[2]: r[-1] for r in self.regenerate.healthy_rows({"x": resynced})}["healthy-mixed"], "fail")
        combo = dict(resynced, params=dict(base["params"], profile="COMBO"))
        self.assertEqual({r[2]: r[-1] for r in self.regenerate.healthy_rows({"x": combo})}["healthy-mixed"], "reported")

    def combo(self, **changes):
        run = self.tracked(self.runs["p0-r1"], profile="COMBO")
        run["params"] = dict(run["params"], cell="M-COMBO", rooms=300, rate="4047216bit")
        g = dict(run["groups"]["impaired"], **changes)
        return dict(run, groups=dict(run["groups"], impaired=g))

    def test_rate_and_combo_resyncs_and_4010_in_the_impaired_window_are_reported_not_failed(self):
        run = self.combo()
        applied = run["timeline"]["appliedAt"]
        g = run["groups"]["impaired"]
        busy = self.combo(resyncs=[{"key": "k1", "t": applied + 4_000}, {"key": "k2", "t": applied + 6_000}],
                          closeMatch=dict(g["closeMatch"], closes=[{"key": "k1", "t": applied + 20_000, "serverKind": "slowConsumer"}]),
                          reconnects=[{"key": "k1", "closedAt": applied + 20_000, "outcome": "recovered", "firstSyncAt": applied + 22_000}])
        row = self.regenerate.rate_rows({"x": busy})[0]
        self.assertEqual(row[3:9], ("2/50", 2, "4000–6000", 1, 1, row[8]))
        self.assertEqual(row[-1], "pass", "the mechanism under the throttle doesn't fail the cell")
        self.assertIn("2.1% (down), up 9750 B/s unshaped", row[10])

    def test_rate_and_combo_recovery_tail_gate(self):
        run = self.combo()
        end = run["timeline"]["liftedAt"] + a.RECOVERY_MS
        tail = self.combo(resyncs=[{"key": "k1", "t": end - 5_000}])
        self.assertEqual(self.regenerate.rate_rows({"x": tail})[0][-1], "fail", "a resync in the last 10 s")
        applied = run["timeline"]["appliedAt"]
        short = self.combo(reconnects=[{"key": "k1", "closedAt": applied + 1_000, "outcome": "recovered", "firstSyncAt": end - 2_000}])
        self.assertEqual(self.regenerate.rate_rows({"x": short})[0][-1],
                         "inconclusive (recovery too short after the last rebuild)")
        g = run["groups"]["impaired"]
        finding = self.combo(closeMatch=dict(g["closeMatch"], closes=[{"key": "k1", "t": applied + 9_000, "serverKind": "unresponsive"}]))
        self.assertIn("4011 ×1", self.regenerate.rate_rows({"x": finding})[0][-2])
        backlog = self.combo(closeMatch=dict(g["closeMatch"], closes=[{"key": "k1", "t": applied + 12_000, "serverKind": "backlogUnwritable"},
                                                                    {"key": "k2", "t": end - 3_000, "serverKind": "backlogBytes"}]))
        row = self.regenerate.rate_rows({"x": backlog})[0]
        self.assertEqual(row[-2], "4008 ×2 at 12000, %d ms after the apply, 1 in the tail" % (end - 3_000 - applied))
        impaired_only = self.combo(closeMatch=dict(g["closeMatch"], closes=[{"key": "k1", "t": applied + 12_000, "serverKind": "backlogBytes"}]))
        self.assertEqual(self.regenerate.rate_rows({"x": impaired_only})[0][-1], "pass", "a 4008 in the impaired window is a finding, not a fail")

    def test_a_stale_calibration_refuses_the_rate_cell(self):
        stale = self.combo()
        stale["params"] = dict(stale["params"], rate="100000bit")
        self.assertRegex(self.regenerate.rate_rows({"x": stale})[0][-1], r"^recalibrate: #344 frames add \d+ % to the calibrated demand$")

    def test_reordering_jitter_is_labelled_and_reported(self):
        base = self.runs["p0-r1"]
        run = dict(base, params=dict(base["params"], profile="D50J10", jitterReorders=True, reorderedPct=0.4))
        runs = {"d50j10-r1": run}
        self.assertEqual(self.regenerate.close_rows(runs)[0][1], "D50J10 (reordering)")
        self.assertEqual(self.regenerate.close_rows(runs)[0][6], "pass", "the stale rule still goes by the profile")
        self.assertEqual(self.regenerate.reorder_rows(runs), [("d50j10-r1", "D50J10 (reordering)", "0.4")])
        per_direction = dict(run, params=dict(run["params"], reorderedPct={"down": 0.614, "up": 0.386}))
        self.assertEqual(self.regenerate.reorder_rows({"x": per_direction})[0][2], "0.614 down, 0.386 up")
        one_side = dict(run, params=dict(run["params"], reorderedPct={"down": 16.13}))
        self.assertEqual(self.regenerate.reorder_rows({"x": one_side})[0][2], "fail (missing: reorderedPct.up)")
        unmeasured = dict(run, params={k: v for k, v in run["params"].items() if k != "reorderedPct"})
        self.assertEqual(self.regenerate.reorder_rows({"x": unmeasured})[0][2], "fail (missing: reorderedPct)")
        # A profile without jitter can't reorder: the flag on BO75 or SR is a bad run.json.
        for profile in ("BO75", "SR", "P0"):
            bad = dict(base, params=dict(base["params"], profile=profile, jitterReorders=True))
            with self.assertRaisesRegex(ValueError, "no jitter"):
                self.regenerate.label(bad)
        self.assertEqual(self.regenerate.reorder_rows(self.runs), [], "in-order hosts: no table")
        self.assertIn("### Jitter with reordering", self.regenerate.tables(dict(self.runs, **runs)))

    def test_isolation_rows_for_the_healthy_group(self):
        rows = self.regenerate.isolation_rows(self.runs)
        self.assertEqual({(r[2], r[3], r[6]) for r in rows}, {("healthy-mixed", "inputP99", "yes"), ("healthy-mixed", "gapP99", "yes"),
                                                             ("healthy-mixed", "closes, unanswered", "yes")})

    def test_isolation_fails_on_a_healthy_close_or_unanswered_or_a_lost_file(self):
        run = self.runs["bo75-r1"]
        healthy = run["groups"]["healthy-mixed"]

        def iso(group, of="bo75-r1", base=None):
            r = base or run
            changed = dict(r, groups=dict(r["groups"], **{"healthy-mixed": group}))
            return {(x[3]): x[6] for x in self.regenerate.isolation_rows(dict(self.runs, **{of: changed})) if x[0] == "bo75-r1"}

        closed = dict(healthy, closes=[{"t": T0 + 1, "key": "h1", "initiator": "server", "code": 1006, "cause": None, "slowReader": False}])
        self.assertEqual(iso(closed)["closes, unanswered"], "no", "a healthy close fails isolation (Review M1)")
        cm = dict(healthy["closeMatch"], duringJoin={"client": 1})
        self.assertEqual(iso(dict(healthy, closeMatch=cm))["closes, unanswered"], "no", "so does one during a join")
        ws = [dict(w, unanswered=1) if i == 0 else w for i, w in enumerate(healthy["windows"])]
        self.assertEqual(iso(dict(healthy, windows=ws))["closes, unanswered"], "no", "and an unanswered action")
        lost = dict(healthy, manifest=dict(healthy["manifest"], files=healthy["manifest"]["files"] - 1 or 0,
                                           joinKeys=healthy["manifest"]["joinKeys"] - 1))
        self.assertTrue(all(v.startswith("fail (missing") for v in iso(lost).values()), "a lost worker file (Review M2)")
        p0 = self.runs["p0-r1"]
        p0_lost = dict(p0["groups"]["healthy-mixed"], manifest=dict(p0["groups"]["healthy-mixed"]["manifest"], joinKeys=0))
        got = iso(p0_lost, of="p0-r1", base=p0)
        self.assertTrue(all("control p0-r1" in v for k, v in got.items() if k != "closes, unanswered"), "a control's lost file")

    def test_memory_rows_apply_the_leak_check_against_p0(self):
        rows = {r[0]: r for r in self.regenerate.memory_rows(self.runs)}
        self.assertEqual(rows["bo75-r1"][4], "fail", "3 MiB/s is above P0's 0 + 1 MiB/s")
        self.assertEqual(rows["p0-r1"][4], "pass")

    def test_memory_and_isolation_fail_on_missing_inputs(self):
        run = self.runs["bo75-r1"]
        rows = self.regenerate.memory_rows({"x": dict(run, memory=None)})
        self.assertEqual(rows[0][4], "fail (missing: memory samples)", "a run without memory data still has a row")
        no_tail = dict(run, memory=dict(run["memory"], rssSlopeLast30sMbPerS=None))
        self.assertEqual(self.regenerate.memory_rows({"x": no_tail})[0][4], "fail (missing: RSS over the last 30 s)")
        self.assertEqual(self.regenerate.memory_rows({"x": run})[0][4], "fail (no control)", "no P0 repeats")
        iso = self.regenerate.isolation_rows({"x": run})
        self.assertEqual({r[6] for r in iso if r[3] != "closes, unanswered"}, {"fail (no control)"})
        empty = dict(run["groups"]["healthy-mixed"], windows=[w for w in run["groups"]["healthy-mixed"]["windows"] if w["segment"] != "impaired"])
        iso = self.regenerate.isolation_rows(dict(self.runs, **{"bo75-r1": dict(run, groups=dict(run["groups"], **{"healthy-mixed": empty}))}))
        self.assertEqual({r[6] for r in iso if r[0] == "bo75-r1" and r[3] != "closes, unanswered"}, {"fail (missing: impaired samples)"})
        p0 = self.runs["p0-r1"]
        uncovered = dict(self.runs, **{"p0-r1": dict(p0, memory=dict(p0["memory"], rssSlopeLast30sMbPerS=None))})
        self.assertEqual({r[0]: r for r in self.regenerate.memory_rows(uncovered)}["bo75-r1"][4],
                         "fail (missing: control p0-r1 RSS over the last 30 s)", "a control's lost tail (Review S3)")

    def test_client_bound_windows_are_excluded_and_counted(self):
        root = tempfile.mkdtemp()
        # Healthy-mixed's worker is busy for 3 s of the impaired segment; those windows also get a
        # latency far over the band, which isolation must not read.
        run = synthetic_run(root, "bo75-busy", "BO75", outage=True, busy=(10_000, 11_000, 12_000), loop_p99=8)
        hm = run["groups"]["healthy-mixed"]
        hot = [dict(w, gapHist={"5000": 50}) if w["clientBound"] else w for w in hm["windows"]]
        run = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(hm, windows=hot)}))
        runs = dict(self.runs, **{"bo75-busy": run})
        rows = {(r[0], r[2]): r for r in self.regenerate.client_bound_rows(runs)}
        # 3 busy spans from x.5 s, each overlapping two windows: 4 windows (the spans are contiguous).
        self.assertEqual(rows[("bo75-busy", "healthy-mixed")][3], "baseline 0, impaired 4, recovery 0")
        self.assertEqual(rows[("bo75-busy", "healthy-mixed")][4], "w0 0.95", "the worker's largest span ELU")
        self.assertEqual(rows[("bo75-busy", "impaired")][3:5], ("baseline 0, impaired 0, recovery 0", "w0 0.2"),
                         "below the gate too, for the headroom")
        self.assertEqual(rows[("bo75-busy", "healthy-mixed")][7], "consistent")
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(runs) if r[0] == "bo75-busy"}
        self.assertEqual(iso["gapP99"], "yes", "the client-bound windows' latency isn't read")
        unflagged = [dict(w, clientBound=False) for w in hot]
        runs2 = dict(self.runs, **{"bo75-busy": dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(hm, windows=unflagged)}))})
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(runs2) if r[0] == "bo75-busy"}
        self.assertEqual(iso["gapP99"], "no", "the same windows read when not client-bound")

    def test_a_controls_client_bound_windows_stay_out_of_the_band(self):
        root = tempfile.mkdtemp()
        p0 = synthetic_run(root, "p0-busy", "P0", busy=(20_000, 21_000))
        g = p0["groups"]["healthy-mixed"]
        hot = [dict(w, gapHist={"5000": 50}, gapP99=5000) if w["clientBound"] else w for w in g["windows"]]
        flagged = dict(g, windows=hot)
        quiet = self.regenerate.quiet_windows(dict(p0, groups=dict(p0["groups"], **{"healthy-mixed": flagged})), "healthy-mixed")
        self.assertFalse(any(w["clientBound"] for w in quiet))
        self.assertLess(a.segment_band([quiet], 10, "gapHist"), 5000, "a control's client-bound latency doesn't widen it")

    def test_a_matcher_that_misses_the_echo_fails_the_group(self):
        # As when the opcode encodings went positional and the matcher still looked for `{v: {x, y}}`.
        rid = "bo75-r1"
        g = self.runs[rid]["groups"]["healthy-mixed"]
        def with_seen(share):
            ws = [dict(w, inputsSeen=int(w["inputsSent"] * share)) for w in g["windows"]]
            return dict(self.runs[rid], groups=dict(self.runs[rid]["groups"], **{"healthy-mixed": dict(g, windows=ws)}))
        self.assertEqual(self.regenerate.missing_inputs(with_seen(1.0), "healthy-mixed"), [])
        missed = self.regenerate.missing_inputs(with_seen(0.05), "healthy-mixed")
        self.assertEqual(len(missed), 1)
        self.assertRegex(missed[0], r"^healthy-mixed baseline inputs seen \d+/\d+ \(input-to-visible matcher\)$")
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(dict(self.runs, **{rid: with_seen(0.05)})) if r[0] == rid}
        self.assertTrue(iso and all(v.startswith("fail (missing: healthy-mixed baseline inputs seen") for v in iso.values()))
        silent = dict(self.runs[rid], groups=dict(self.runs[rid]["groups"], **{"healthy-mixed": dict(
            g, windows=[dict(w, inputsSent=0, inputsSeen=0) for w in g["windows"]])}))
        self.assertIn("healthy-mixed baseline inputs (0 sent)", self.regenerate.missing_inputs(silent, "healthy-mixed"))

    def test_a_stopped_sampler_fails_the_group(self):
        g = self.runs["bo75-r1"]["groups"]["healthy-mixed"]
        stopped = dict(g, loop=dict(g["loop"], uncovered={"w0": "gap 40000 ms from 120000 ms"}))
        run = dict(self.runs["bo75-r1"], groups=dict(self.runs["bo75-r1"]["groups"], **{"healthy-mixed": stopped}))
        self.assertEqual(self.regenerate.missing_inputs(run, "healthy-mixed"),
                         ["healthy-mixed loop spans for worker w0 (gap 40000 ms from 120000 ms)"])
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(dict(self.runs, **{"bo75-r1": run})) if r[0] == "bo75-r1"}
        self.assertTrue(all(v.startswith("fail (missing: healthy-mixed loop spans for worker w0") for v in iso.values()))

    def test_a_worker_file_without_loop_spans_is_uncovered(self):
        root = pathlib.Path(tempfile.mkdtemp())
        synthetic_run(root, "p0-w1", "P0")
        # A second worker of the healthy instance whose sampler never wrote a span.
        with gzip.open(root / "p0-w1" / "samples" / "lt-good" / "w1.ndjson.gz", "wt") as f:
            f.write(json.dumps({"r": "phase", "name": "steady", "originAt": T0, "endAt": T0 + 1}) + "\n")
        loop = a.ingest(root / "p0-w1")["groups"]["healthy-mixed"]["loop"]
        self.assertEqual(list(loop["uncovered"]), ["w1"], "every worker file counts, not only those with spans")

    def test_mostly_client_bound_segments_are_inconclusive(self):
        root = tempfile.mkdtemp()
        # 12 busy seconds in the impaired segment: 13 of 60 windows (22 %) are client-bound.
        busy = synthetic_run(root, "bo75-hot", "BO75", outage=True, busy=tuple(range(20_000, 32_000, 1_000)))
        runs = dict(self.runs, **{"bo75-hot": busy})
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(runs) if r[0] == "bo75-hot"}
        self.assertEqual((iso["inputP99"], iso["gapP99"]), ("inconclusive (22% client-bound)",) * 2)
        self.assertEqual(iso["closes, unanswered"], "yes", "the close criterion isn't affected")
        few = synthetic_run(root, "bo75-warm", "BO75", outage=True, busy=tuple(range(20_000, 30_000, 1_000)))
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(dict(self.runs, **{"bo75-warm": few})) if r[0] == "bo75-warm"}
        self.assertEqual(iso["gapP99"], "yes", "11 of 60 (18 %) still judges")
        # A control with 35 % of its quiet windows client-bound.
        hot_p0 = synthetic_run(root, "p0-r1", "P0", busy=tuple(range(-30_000, 1_000, 1_000)))
        iso = {r[3]: r[6] for r in self.regenerate.isolation_rows(dict(self.runs, **{"p0-r1": hot_p0})) if r[0] == "bo75-r1"}
        self.assertTrue(iso["gapP99"].startswith("inconclusive (") and iso["gapP99"].endswith("in control p0-r1"), iso["gapP99"])
        # Recovery: 25 of 90 recovery windows client-bound.
        late = synthetic_run(root, "bo75-late", "BO75", outage=True, busy=tuple(range(70_000, 94_000, 1_000)))
        rows = {(p, g): v for _, p, g, v in self.regenerate.recovery_rows(dict(self.runs, **{"bo75-r1": late}))}
        self.assertEqual(rows[("BO75", "healthy-mixed")], ["inconclusive (28% client-bound)"])

    def test_the_client_bound_gate_check(self):
        root = tempfile.mkdtemp()
        rows = lambda run: {r[2]: r for r in self.regenerate.client_bound_rows({"x": run})}
        high = synthetic_run(root, "p0-high", "P0", loop_p99=35)
        self.assertTrue(rows(high)["impaired"][7].startswith("gate too high?"), "loop p99 over 20 ms, no window flagged")
        self.assertEqual(rows(synthetic_run(root, "p0-none", "P0"))["impaired"][7], "missing: run-wide loop-delay p99")
        busy = synthetic_run(root, "p0-busy", "P0", busy=(5_000,), loop_p99=35)
        self.assertEqual(rows(busy)["healthy-mixed"][7], "consistent")
        g = dict(high["groups"]["impaired"], loop={"spans": 0, "maxEluByWorker": {}})
        lost = dict(high, groups=dict(high["groups"], impaired=g))
        self.assertEqual(rows(lost)["impaired"][7], "fail (missing: impaired loop samples)")
        self.assertIn("impaired loop samples", self.regenerate.missing_inputs(lost, "impaired"),
                      "every hard criterion of the group fails without them")

    def test_tables_render(self):
        text = self.regenerate.tables(self.runs)
        self.assertTrue(text.startswith(f"Provenance, from the results' meta: commit `{'a' * 40}`, clean tree; "), text[:200])
        for heading in ("### Recovery", "### Per-session recovery", "### Closes and server causes", "### Every room converged",
                        "### Isolation", "### Memory"):
            self.assertIn(heading, text)



def convergence_report(lands, roster=None, **totals):
    """A report; its roster defaults to one lt-client connection per listed land."""
    base = {"lands": len(lands), "converged": 0, "convergedLate": 0, "mismatched": 0, "missingClients": 0, "inconclusive": 0,
            "errors": 0, "uncheckedAtDeadline": 0, "lateMaxMs": None,
            "survivors": {"compared": 4, "converged": 4, "convergedLate": 0}, "reconnected": {"compared": 1, "converged": 1, "convergedLate": 0}}
    for land in lands:
        key = {"converged": "converged", "convergedLate": "convergedLate", "mismatched": "mismatched", "missingClients": "missingClients",
               "inconclusive": "inconclusive", "error": "errors"}[land["outcome"]]
        base[key] += 1
    late = [land["lateMs"] for land in lands if "lateMs" in land]
    base["lateMaxMs"] = max(late) if late else None
    base.update(totals)
    if roster is None:
        roster = {"lt-client": {land["land"]: 1 for land in lands}}
    return {"startedAt": 1_000, "sendingStoppedAt": 1_010, "endedAt": 13_500, "roster": roster, "lands": lands, "totals": base}


def land(name, outcome, connections=(), **extra):
    return {"land": name, "outcome": outcome, "attempts": 1, "connections": list(connections), **extra}


def read_report(report):
    d = pathlib.Path(tempfile.mkdtemp())
    (d / "convergence.json").write_text(json.dumps(report))
    return a.read_convergence(d / "convergence.json")


class ConvergenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import regenerate
        cls.regenerate = regenerate

    def run_with(self, report, rooms=2, roster=None):
        params = {"rooms": rooms, "population": "U", "profile": "P0", "convergenceRoster": roster or {"lt-client": {"1": rooms}}}
        return {"params": params, "convergence": None if report is None else read_report(report)}

    def test_read_convergence_keeps_totals_and_the_rooms_that_did_not_converge(self):
        d = pathlib.Path(tempfile.mkdtemp())
        mismatch = {"key": "k1", "instance": "lt-client", "outcome": "mismatched", "reconnected": False, "differences": 1,
                    "paths": [{"path": "/hp", "client": 1, "server": 2}], "player": "0", "decodeErrors": 0}
        ok = dict(mismatch, key="k2", outcome="converged", differences=0, paths=[])
        (d / "convergence.json").write_text(json.dumps(convergence_report([land("r0", "converged", [ok]), land("r1", "mismatched", [ok, mismatch])])))
        conv = a.read_convergence(d / "convergence.json")
        self.assertEqual(conv["durationMs"], 12_500)
        self.assertEqual([l["land"] for l in conv["notConverged"]], ["r1"])
        self.assertEqual([c["key"] for c in conv["notConverged"][0]["connections"]], ["k1"])
        self.assertIsNone(a.read_convergence(d / "absent.json"), "no file: a missing input, not an empty check")

    def test_criterion_3_verdicts(self):
        verdict = lambda report, rooms=2: self.regenerate.convergence_rows({"x": self.run_with(report, rooms)})[0][-1]
        self.assertEqual(verdict(convergence_report([land("r0", "converged"), land("r1", "converged")])), "pass")
        self.assertEqual(verdict(None), "fail (missing: convergence)")
        self.assertEqual(verdict(convergence_report([])), "fail (no rooms checked)")
        self.assertEqual(verdict(convergence_report([land("r0", "converged")])), "fail (1 of 2 rooms listed)")
        # The deadline left one room unchecked: an error, with its own verdict and count.
        late = convergence_report([land("r0", "converged"), land("r1", "error")], uncheckedAtDeadline=1)
        self.assertEqual(verdict(late), "fail (1 of 2 rooms checked before the deadline)")
        self.assertEqual(self.regenerate.convergence_rows({"x": self.run_with(late)})[0][2], "1/2")
        for outcome in ("mismatched", "missingClients", "error"):
            self.assertEqual(verdict(convergence_report([land("r0", "converged"), land("r1", outcome)])), "fail", outcome)
        self.assertEqual(verdict(convergence_report([land("r0", "converged"), land("r1", "inconclusive")])), "inconclusive (1 rooms)")
        row = self.regenerate.convergence_rows({"x": self.run_with(convergence_report([land("r0", "converged"), land("r1", "converged")]))})[0]
        self.assertEqual(row[2], "2/2", "rooms checked before the deadline, of the run's")
        self.assertEqual(row[9:12], ("4/4", "1/1", 12.5), "survivors and reconnected apart, and the pass's wall time")

    def test_a_room_that_converged_late_passes_in_its_own_column(self):
        report = convergence_report([land("r0", "converged"), land("r1", "convergedLate", lateMs=420)],
                                    survivors={"compared": 4, "converged": 3, "convergedLate": 1})
        row = self.regenerate.convergence_rows({"x": self.run_with(report)})[0]
        self.assertEqual(row[3:5], (1, "1 (max 420 ms)"))
        self.assertEqual(row[9], "4/4", "a late connection converged")
        self.assertEqual(row[-1], "pass")
        conv = read_report(report)
        self.assertEqual(conv["late"], [{"land": "r1", "lateMs": 420}])
        self.assertEqual(conv["notConverged"], [])

    def test_the_roster_must_match_the_run(self):
        verdict = lambda report, roster, rooms=2: self.regenerate.convergence_rows({"x": self.run_with(report, rooms, roster)})[0][-1]
        lands = [land("r0", "converged"), land("r1", "converged")]
        # M: lt-client has 1 connection in each room, lt-good 4.
        both = {"lt-client": {"r0": 1, "r1": 1}, "lt-good": {"r0": 4, "r1": 4}}
        expected = {"lt-client": {"1": 2}, "lt-good": {"4": 2}}
        self.assertEqual(verdict(convergence_report(lands, roster=both), expected), "pass")
        # The driver was run without lt-good's control socket: every room still converged.
        alone = {"lt-client": {"r0": 1, "r1": 1}}
        self.assertEqual(verdict(convergence_report(lands, roster=alone), expected),
                         "fail (roster: lt-good none, expected 4 in 2)")
        short = {"lt-client": {"r0": 1, "r1": 1}, "lt-good": {"r0": 4, "r1": 3}}
        self.assertEqual(verdict(convergence_report(lands, roster=short), expected),
                         "fail (roster: lt-good 3 in 1, 4 in 1, expected 4 in 2)")
        # Without the run's roster, or a report without one, the check can't be made.
        run = self.run_with(convergence_report(lands))
        del run["params"]["convergenceRoster"]
        self.assertEqual(self.regenerate.convergence_rows({"x": run})[0][-1], "fail (missing: params.convergenceRoster)")
        old = convergence_report(lands)
        del old["roster"]
        self.assertEqual(verdict(old, {"lt-client": {"1": 2}}), "fail (missing: convergence roster)")


def opened(sid, port, t, host="10.201.0.2"):
    return {"event": "sessionOpened", "sessionID": sid, "peerHost": host, "peerPort": port, "wallMs": t}


def decided(sid, code, t):
    return {"event": "syncLagCloseDecided", "sessionID": sid, "code": code, "wallMs": t}


def socket(k, port, connected, ended, end, opened_at=None, joined_at=None):
    r = {"r": "socket", "k": k, "localPort": port, "connectedAt": connected, "endedAt": ended, "end": end}
    if opened_at is not None:
        r["openedAt"] = opened_at
    if joined_at is not None:
        r["joinedAt"] = joined_at
    return r


class PairingTests(unittest.TestCase):
    """#490: each server session pairs with the client socket it was, by port and connect time, so
    a liveness close of a socket the client had already given up on isn't a server-only close. The
    shapes are r1–r3's of the 48962fae RATE runs (times relative to the apply, T0)."""

    # r1's never-joined shape: the client's attempt connected, the server's 101 never reached it,
    # the tool terminated it at 5 s, and the server closed it by its pong timeout at apply +38,308.
    NEVER_JOINED = [opened("n1", 58842, T0 + 8_000), closed("n1", "pongTimeout", T0 + 38_308, 1001)]
    NEVER_JOINED_SOCKET = socket("lt-client-n", 58842, T0 + 7_700, T0 + 12_700, "attemptTimeout")
    # r1 7D57B5A1's shape: joined on the server at apply +14,923, its JoinResponse never arrived,
    # the tool terminated the attempt, and the server closed it with 4011 10,007 ms after the join.
    J = T0 + 14_923
    JOINED = [opened("j1", 60894, J - 400), joined("j1", "g-j1", J), closed("j1", "serverClose", J + 10_007, 4011)]
    JOINED_SOCKET = socket("lt-client-j", 60894, J - 2_100, J + 2_900, "attemptTimeout", opened_at=J - 1_700)

    def log(self, lines):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "l.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))
        return a.read_lifecycle(d / "l.jsonl")

    def test_the_new_lines_are_read_apart_from_joins_and_closes(self):
        log = self.log([opened("s1", 58842, T0), decided("s1", 4010, T0 + 10), closed("s1", "connectionLost", T0 + 20),
                        decided("s1", 4010, T0 + 30), opened("s2", 58843, T0 + 40)])
        self.assertEqual(log["s1"]["opened"], {"peerHost": "10.201.0.2", "peerPort": 58842, "t": T0})
        self.assertEqual(log["s1"]["close"]["cause"], "connectionLost", "a decision line is never read as a close")
        self.assertEqual([d["t"] for d in log["s1"]["lagCloses"]], [T0 + 10, T0 + 30])
        self.assertEqual(log["s2"], {"joins": [], "close": None, "opened": {"peerHost": "10.201.0.2", "peerPort": 58843, "t": T0 + 40},
                                     "lagCloses": []})
        self.assertTrue(a.has_opened_lines(log))
        self.assertFalse(a.has_opened_lines(self.log([joined("s3", "p", T0), closed("s3", "clientClose", T0 + 1)])))
        self.assertEqual(a.unjoined_server_closes(log, T0, T0 + 100), [], "an opened-only session is no unjoined close")

    def test_a_session_pairs_with_the_latest_connect_on_its_port_before_it_opened(self):
        log = self.log(self.NEVER_JOINED + self.JOINED)
        by_port = a.sockets_by_port([self.NEVER_JOINED_SOCKET, self.JOINED_SOCKET])
        self.assertEqual(a.socket_of(log["n1"], by_port)["k"], "lt-client-n")
        self.assertEqual(a.socket_of(log["j1"], by_port)["k"], "lt-client-j")

    def test_the_server_may_open_after_the_client_gave_up(self):
        # The server writes sessionOpened after the upgrade; a client that gave up at its 5 s
        # timeout can end before that. Pairing by connect time still finds it (Review S1).
        log = self.log([opened("late", 59000, T0 + 20_000), closed("late", "pongTimeout", T0 + 50_000, 1001)])
        s = socket("lt-client-late", 59000, T0 + 14_500, T0 + 19_500, "attemptTimeout")
        paired = a.pair_server_only([{"sessionID": "late", "cause": "pongTimeout", "code": 1001, "t": T0 + 50_000}],
                                    log, a.sockets_by_port([s]))[0]
        self.assertEqual(paired["socket"]["key"], "lt-client-late")
        self.assertEqual(a.abandoned_kind(paired), "abandoned")

    def test_a_reused_port_pairs_with_the_socket_that_connected_last_before_the_open(self):
        log = self.log([opened("r", 58842, T0 + 30_000), closed("r", "pongTimeout", T0 + 70_000, 1001)])
        older = socket("lt-client-a", 58842, T0 - 25_000, T0 - 20_000, "closed", joined_at=T0 - 24_000)
        this = socket("lt-client-b", 58842, T0 + 29_700, T0 + 34_700, "attemptTimeout")
        later = socket("lt-client-c", 58842, T0 + 50_000, T0 + 55_000, "attemptTimeout")
        self.assertEqual(a.socket_of(log["r"], a.sockets_by_port([older, later, this]))["k"], "lt-client-b")

    def test_the_key_is_the_address_and_the_port(self):
        # M runs two client namespaces: the same port from the other one is another socket.
        log = self.log([opened("m", 58842, T0 + 30_000, host="10.201.0.2")])
        mine = dict(socket("lt-client-m", 58842, T0 + 29_000, T0 + 34_000, "attemptTimeout"), localAddress="::ffff:10.201.0.2")
        other = dict(socket("lt-good-m", 58842, T0 + 29_500, T0 + 34_500, "closed"), localAddress="10.201.0.3")
        self.assertEqual(a.socket_of(log["m"], a.sockets_by_port([mine, other]))["k"], "lt-client-m")
        self.assertIsNone(a.socket_of(log["m"], a.sockets_by_port([other])))

    def test_only_a_liveness_close_of_a_socket_the_client_ended_first_is_abandoned(self):
        base = {"sessionID": "x", "cause": "pongTimeout", "code": 1001, "t": T0 + 38_308}
        s = {"key": "k", "end": "attemptTimeout", "connectedAt": T0 + 7_700, "endedAt": T0 + 12_700}
        cases = (("pong timeout, attempt timed out", base, s, "abandoned"),
                 ("4011, join timed out", dict(base, cause="serverClose", code=4011), dict(s, end="joinTimeout"), "abandoned"),
                 ("phaseEnd socket", base, dict(s, end="phaseEnd"), "phaseEnd"),
                 ("4010 isn't liveness", dict(base, cause="serverClose", code=4010), s, None),
                 ("a closed socket needs its client close", base, dict(s, end="closed"), None),
                 ("the client's socket outlived the close", base, dict(s, endedAt=T0 + 40_000), None),
                 ("no socket", base, None, None))
        for name, close, sock, want in cases:
            with self.subTest(name):
                self.assertEqual(a.abandoned_kind(dict(close, socket=sock)), want)

    def paired_run(self, extra_log, sockets, counts=True, opened_lines=True):
        """A P0 run (`synthetic_run`) with r1's two shapes added: their server lines, and the client
        sockets in a second worker file; ``opened_lines=False`` is the same run from a server before
        #490 (no `sessionOpened`)."""
        root = tempfile.mkdtemp()
        synthetic_run(root, "x", "P0")
        d = pathlib.Path(root) / "x"
        lines = [l for l in extra_log if opened_lines or l["event"] != "sessionOpened"]
        if opened_lines:
            # The run's own sessions get their opened lines too: the whole log is from one server.
            for l in (json.loads(x) for x in (d / "land-lifecycle.jsonl").read_text().splitlines()):
                if l["event"] == "sessionJoined":
                    lines.append(opened(l["sessionID"], 40_000 + len(lines), l["wallMs"] - 100))
        with (d / "land-lifecycle.jsonl").open("a") as f:
            f.write("".join(json.dumps(l) + "\n" for l in lines))
        # Into each worker's own file (a second file without loop spans would fail the client-bound
        # gate), each file closed with its `sockets` line, as a worker process writes it at shutdown.
        for instance, mine in (("lt-client", list(sockets)), ("lt-good", [])):
            records = mine + ([{"r": "sockets", "created": len(mine), "recorded": len(mine), "leftAtExit": 0}] if counts else [])
            w0 = d / "samples" / instance / "w0.ndjson.gz"
            with gzip.open(w0, "rt") as f:
                kept = f.read()
            with gzip.open(w0, "wt") as f:
                f.write(kept + "".join(json.dumps(r) + "\n" for r in records))
        run = a.ingest(d)
        # The profile counts the pong-timeout closes the log has (criterion 2's counter check).
        pongs = sum(1 for l in extra_log if l.get("cause") == "pongTimeout")
        return dict(run, server=dict(run["server"], pongTimeoutCloses=run["server"]["pongTimeoutCloses"] + pongs))

    def test_criterion_2_takes_out_the_abandoned_liveness_closes(self):
        import regenerate
        run = self.paired_run(self.NEVER_JOINED + self.JOINED, [self.NEVER_JOINED_SOCKET, self.JOINED_SOCKET])
        self.assertTrue(run["pairedByPort"])
        self.assertEqual(len(run["serverOnly"]), 2)
        row = regenerate.match_rows({"x": run})[0]
        self.assertEqual((row[5], row[-1]), (0, "pass"), row)
        self.assertEqual(regenerate.abandoned_rows({"x": run})[0][2:],
                         ("pongTimeout 1001 ×1, serverClose 4011 ×1", "0", 0, 0, 0, "pass"))

    def test_a_server_close_with_no_client_socket_still_fails(self):
        import regenerate
        stray = [opened("u1", 61000, T0 + 9_000), closed("u1", "pongTimeout", T0 + 40_000, 1001)]
        run = self.paired_run(self.NEVER_JOINED + stray, [self.NEVER_JOINED_SOCKET])
        row = regenerate.match_rows({"x": run})[0]
        self.assertEqual((row[5], row[-1]), (1, "fail"))
        self.assertEqual(regenerate.abandoned_rows({"x": run})[0][2:6], ("pongTimeout 1001 ×1", "0", 1, 1))

    def test_a_record_from_before_490_keeps_its_verdict(self):
        import regenerate
        run = self.paired_run(self.NEVER_JOINED + self.JOINED, [self.NEVER_JOINED_SOCKET, self.JOINED_SOCKET], opened_lines=False)
        self.assertNotIn("pairedByPort", run)
        self.assertNotIn("lagCloseDecisions", run)
        self.assertTrue(all("socket" not in c for c in run["serverOnly"]), "the result is what ingest wrote before #490")
        row = regenerate.match_rows({"x": run})[0]
        self.assertEqual((row[5], row[-1]), (2, "fail"), "the 48962fae RATE shape (13 + 3 there) still fails")
        self.assertEqual(regenerate.abandoned_rows({"x": run}), [])

    def test_one_record_per_socket_is_checked_from_the_data(self):
        import regenerate
        run = self.paired_run(self.NEVER_JOINED, [self.NEVER_JOINED_SOCKET])
        self.assertEqual(run["socketCounts"], {"created": 1, "recorded": 1, "leftAtExit": 0,
                                               "workerFiles": 2, "socketsLines": 2, "socketRecords": 1})
        self.assertEqual(regenerate.abandoned_rows({"x": run})[0][-1], "pass")
        no_lines = self.paired_run(self.NEVER_JOINED, [self.NEVER_JOINED_SOCKET], counts=False)
        self.assertEqual(regenerate.abandoned_rows({"x": no_lines})[0][-1], "fail (a sockets line in 0 of 2 worker files)")
        counts = run["socketCounts"]
        lost = dict(run, socketCounts=dict(counts, recorded=2))
        self.assertEqual(regenerate.abandoned_rows({"x": lost})[0][-1], "fail (2 recorded, 1 socket records read)")
        left = dict(run, socketCounts=dict(counts, created=2, leftAtExit=1))
        self.assertEqual(regenerate.abandoned_rows({"x": left})[0][-2:], (1, "fail (1 sockets without a record)"))

    def test_a_run_judged_by_another_analysis_py_is_refused(self):
        # The re-run's tables depend on analysis.py's rule at regenerate time: a run frozen with
        # another rule is refused, not printed (Review S2). A run with no recorded hash isn't checked.
        import regenerate
        run = self.paired_run(self.NEVER_JOINED, [self.NEVER_JOINED_SOCKET])
        same = dict(run, meta=dict(run["meta"], analysisSha256=regenerate.analysis_sha256()))
        self.assertIsInstance(regenerate.tables({"x": same}), str)
        other = dict(run, meta=dict(run["meta"], analysisSha256="0" * 64))
        with self.assertRaises(SystemExit) as refused:
            regenerate.tables({"x": other})
        self.assertIn("judged by analysis.py 000000000000", str(refused.exception))
        self.assertIsInstance(regenerate.tables({"x": run}), str, "no recorded hash: an older run, not checked")

    def test_the_hash_ignores_line_endings(self):
        import regenerate
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "lf.py").write_bytes(b"a = 1\nb = 2\n")
        (d / "crlf.py").write_bytes(b"a = 1\r\nb = 2\r\n")
        self.assertEqual(regenerate.analysis_sha256(d / "lf.py"), regenerate.analysis_sha256(d / "crlf.py"))


class LagDecisionTests(unittest.TestCase):
    """#490: the sync-lag counters count decisions; each decision has a line naming its session,
    whose close lands with the code or is superseded. r3's shape: one 4010 more counted than logged."""

    def test_each_decision_landed_superseded_or_without_a_close(self):
        d = pathlib.Path(tempfile.mkdtemp())
        lines = [decided("s1", 4010, T0 + 52_000), closed("s1", "serverClose", T0 + 52_050, 4010),
                 decided("s2", 4010, T0 + 53_000), closed("s2", "connectionLost", T0 + 53_002),
                 decided("s3", 4011, T0 + 54_000),
                 decided("s4", 4010, T0 + 200_000), closed("s4", "serverClose", T0 + 200_050, 4010)]
        (d / "l.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))
        out = a.lag_decisions(a.read_lifecycle(d / "l.jsonl"), T0 - 30_000, T0 + 150_000)
        self.assertEqual(out["4010"], {"decided": 2, "landed": 1, "superseded": {"connectionLost": 1}, "noClose": 0})
        self.assertEqual(out["4011"], {"decided": 1, "landed": 0, "superseded": {}, "noClose": 1})
        self.assertEqual(out["4012"], {"decided": 0, "landed": 0, "superseded": {}, "noClose": 0})

    def rate_run(self, slow_logged, slow_counted, decisions=None):
        import regenerate
        root = tempfile.mkdtemp()
        base = synthetic_run(root, "x", "P0")
        run = RegenerateTests.tracked(self, base, profile="RATE", slow=slow_logged)
        run = dict(run, server=dict(run["server"], syncLagSlowConsumerCloses=slow_counted))
        if decisions is not None:
            zero = {"decided": 0, "landed": 0, "superseded": {}, "noClose": 0}
            run["lagCloseDecisions"] = {"4010": dict(zero, **decisions), "4011": dict(zero), "4012": dict(zero)}
        return regenerate, run

    def test_a_superseded_decision_passes_when_every_count_agrees(self):
        r, run = self.rate_run(1223, 1224, {"decided": 1224, "landed": 1223, "superseded": {"connectionLost": 1}})
        self.assertFalse(r.sync_lag_rows({"x": run})[0][-1].startswith("fail"), r.sync_lag_rows({"x": run})[0][-1])
        self.assertEqual(r.lag_decision_rows({"x": run})[0][2:], ("4010", 1224, 1223, "connectionLost 1", 0, "pass"))

    def test_without_decision_lines_r3_still_fails(self):
        r, run = self.rate_run(1223, 1224)
        self.assertEqual(r.sync_lag_rows({"x": run})[0][-1], "fail (4010: log 1223, counter 1224)")
        self.assertEqual(r.lag_decision_rows({"x": run}), [])

    def test_a_counter_off_its_decisions_or_a_decision_without_a_close_fails(self):
        r, off = self.rate_run(1223, 1225, {"decided": 1224, "landed": 1223, "superseded": {"connectionLost": 1}})
        self.assertEqual(r.sync_lag_rows({"x": off})[0][-1], "fail (4010: decisions 1224, counter 1225)")
        r, lost = self.rate_run(1223, 1224, {"decided": 1224, "landed": 1223, "noClose": 1})
        self.assertEqual(r.sync_lag_rows({"x": lost})[0][-1], "fail (4010: 1 decision(s) with no close)")
        self.assertEqual(r.lag_decision_rows({"x": lost})[0][-1], "fail")


if __name__ == "__main__":
    unittest.main()
