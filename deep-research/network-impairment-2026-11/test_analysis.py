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

    def test_survivor_rebuilt_and_lost_sessions(self):
        end = T0 + 60_000 + 90_000
        records = [
            # survivor: joined throughout, steady updates
            {"r": "join", "k": "s", "t": T0 - 40_000, "land": "l", "player": "p1"},
            *self.gaps("s", end - 10_000, end),
            # rebuilt: closed by the server, reconnected with a firstSync
            {"r": "join", "k": "r", "t": T0 - 40_000, "land": "l", "player": "p2"},
            {"r": "close", "key": "r", "t": T0 + 30_000, "joined": True, "initiator": "server", "player": "p2"},
            {"r": "join", "k": "r", "t": T0 + 61_000, "land": "l", "player": "p2"},
            {"r": "reconnect", "k": "r", "key": "r", "outcome": "recovered", "firstSyncAt": T0 + 61_100, "closedAt": T0 + 30_000},
            *self.gaps("r", end - 10_000, end),
            # lost: closed, reconnect gave up
            {"r": "join", "k": "x", "t": T0 - 40_000, "land": "l", "player": "p3"},
            {"r": "close", "key": "x", "t": T0 + 30_000, "joined": True, "initiator": "server", "player": "p3"},
            {"r": "reconnect", "k": "x", "key": "x", "outcome": "gaveUp", "closedAt": T0 + 30_000},
        ]
        got = a.sessions(records, self.timeline())
        self.assertEqual((got["s"]["closes"], got["s"]["reconnected"], got["s"]["openAtEnd"]), (0, False, True))
        self.assertEqual((got["r"]["reconnected"], got["r"]["rebuilt"], got["r"]["openAtEnd"]), (True, True, True))
        self.assertEqual((got["x"]["rebuilt"], got["x"]["openAtEnd"]), (False, False))
        self.assertEqual(got["s"]["lastGapP99"], 100)
        self.assertTrue(a.session_recovered(got["s"], 150))
        self.assertTrue(a.session_recovered(got["r"], 150))
        self.assertFalse(a.session_recovered(got["x"], 150))
        self.assertFalse(a.session_recovered(got["s"], 99), "its last 10 s gap p99 is above the band")
        self.assertFalse(a.session_recovered(got["s"], None), "no P0 band: the check can't be made, so it fails")

    def test_quiet_windows_and_the_session_band(self):
        records = [
            {"r": "join", "k": "s", "t": T0 - 40_000, "land": "l", "player": "p1"},
            *self.gaps("s", T0 - 30_000, T0 - 20_000, 100),
            *self.gaps("s", T0 - 20_000, T0 - 10_000, 250),
        ]
        got = a.sessions(records, self.timeline())
        self.assertEqual(got["s"]["quietGapP99s"], [100, 250], "one value per 10 s quiet window with updates")
        self.assertEqual(a.session_band([got, {"t": {"quietGapP99s": [400]}}]), 400)
        self.assertIsNone(a.session_band([]))

    def test_rebuilt_requires_a_first_sync(self):
        s = {"openAtEnd": True, "reconnected": True, "rebuilt": False, "lastGapP99": 100}
        self.assertFalse(a.session_recovered(s, 150))


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
        self.assertEqual(got, [{"key": "c1", "sessionID": "s1b", "serverCause": "pongTimeout", "serverT": T0 + 30_000,
                                "firstSyncAt": T0 + 62_000}],
                         "c2 joined after the apply; c1's session is its latest join before the apply; its "
                         "firstSync is the first recovered one after the apply, not the earlier or the failed one")


def synthetic_run(root, run_id, profile, outage=False, conns=50):
    """A run directory with two groups of ``conns`` connections each: one action, one move event
    and one update per connection per second. With ``outage``, the impaired group goes silent
    during the impaired segment, is closed by the server 30 s in, and reconnects 1 s after the
    lift with a firstSync."""
    d = pathlib.Path(root) / run_id
    lifted = T0 + 60_000
    (d / "impairment-timeline.json").parent.mkdir(parents=True, exist_ok=True)
    (d / "impairment-timeline.json").write_text(json.dumps(timeline_entries(lifted=lifted, profile=profile)))
    (d / "run.json").write_text(json.dumps({
        "meta": {}, "params": {"rooms": 10, "population": "M"},
        "groups": {
            "impaired": {"instance": "lt-client", "target": conns, "sendTargetPerS": conns},
            "healthy-mixed": {"instance": "lt-good", "target": conns, "sendTargetPerS": conns},
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
        self.assertEqual(rows["bo75-r1"][2:], (50, 50, 0, 0, 0, "pongTimeout 50", counted, "pass"))
        self.assertEqual(rows["p0-r1"][2:], (0, 0, 0, 0, 0, "–", counted, "pass"))

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
        only = dict(run, serverOnly=[{"sessionID": "s9", "cause": "pongTimeout", "t": T0}])
        self.assertEqual(self.regenerate.match_rows({"x": only})[0][5:], (1, 0, "–", "pongTimeoutCloses +0, sendBacklogCloses +0", "fail"))
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
        self.assertEqual(sessions["impaired"][-1], "fail (no control)", "no band never means accept")

    def with_subjects(self, run, change, group="impaired"):
        g = run["groups"][group]
        return dict(run, groups=dict(run["groups"], **{group: dict(g, outageSessions=[change(dict(s)) for s in g["outageSessions"]])}))

    def test_bo75_every_session_open_at_the_apply_is_closed_and_rebuilt(self):
        rows = {(r[0], r[2]): r[3:] for r in self.regenerate.profile_rows(self.runs)}
        self.assertEqual(rows[("bo75-r1", "impaired")], (50, 50, 50, 0, "pass"))
        self.assertNotIn(("bo75-r1", "healthy-mixed"), rows, "healthy groups are judged by isolation")
        self.assertFalse(any(rid.startswith("p0") for rid, _ in rows), "only BO75 and SR have these criteria")
        subjects = self.runs["bo75-r1"]["groups"]["impaired"]["outageSessions"]
        self.assertEqual(subjects[0]["serverCause"], "pongTimeout")
        self.assertEqual(subjects[0]["firstSyncAt"], T0 + 60_000 + 1_100)

    def test_bo75_fails_on_a_wrong_cause_a_late_rebuild_or_a_stale_close_without_pong(self):
        run = self.runs["bo75-r1"]
        lifted = run["timeline"]["liftedAt"]
        def client_close(s):
            s["serverCause"] = "clientClose"
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
                             ("rebuilt 60.001 s after the lift", self.with_subjects(run, late)),
                             ("never rebuilt", self.with_subjects(run, never)),
                             ("closed after recovery", self.with_subjects(run, after_recovery))):
            self.assertEqual(self.regenerate.profile_rows({"x": broken})[0][-1], "fail", name)
        g = run["groups"]["healthy-mixed"]
        stale = dict(g["closeMatch"], closes=[{"key": "h", "t": T0, "code": 1000, "cause": "stale", "sessionID": "s",
                                                "serverCause": "clientClose", "serverCode": 1000, "serverT": T0}])
        broken = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(g, closeMatch=stale)}))
        self.assertEqual(self.regenerate.profile_rows({"x": broken})[0][-2:], (1, "fail"),
                         "a stale close anywhere in a BO75 run must match a pong or backlog close")
        late = dict(stale, closes=[dict(stale["closes"][0], serverCause="pongTimeout", serverT=run["timeline"]["liftedAt"] + a.RECOVERY_MS)])
        broken = dict(run, groups=dict(run["groups"], **{"healthy-mixed": dict(g, closeMatch=late)}))
        self.assertEqual(self.regenerate.profile_rows({"x": broken})[0][-2:], (1, "fail"), "matched only after recovery")

    def test_the_per_profile_criteria_fail_on_missing_inputs(self):
        run = self.runs["bo75-r1"]
        no_log = dict(run, groups=dict(run["groups"], impaired=dict(run["groups"]["impaired"], outageSessions=None)))
        self.assertEqual(self.regenerate.profile_rows({"x": no_log})[0][-1], "fail (missing: lifecycle log)")
        short = dict(run, groups=dict(run["groups"], impaired=dict(
            run["groups"]["impaired"], outageSessions=run["groups"]["impaired"]["outageSessions"][:49])))
        self.assertEqual(self.regenerate.profile_rows({"x": short})[0][-1], "fail (49/50 open at the apply)")

    def test_sr_needs_a_backlog_close_on_the_server_and_a_rebuild_by_the_end(self):
        base = self.runs["bo75-r1"]
        sr = dict(base, params=dict(base["params"], population="SR", profile="SR"))
        self.assertEqual(self.regenerate.profile_rows({"x": sr})[0][-1], "fail", "a pong timeout is not 4008")
        lifted = base["timeline"]["liftedAt"]
        def backlog(s):
            s["serverCause"] = "backlogUnwritable"
            s["firstSyncAt"] = lifted + 80_000
            return s
        row = self.regenerate.profile_rows({"x": self.with_subjects(sr, backlog)})[0]
        self.assertEqual(row[-2:], ("–", "pass"), "4008, and a firstSync within the recovery segment")

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
        self.assertEqual(self.regenerate.reorder_rows({"x": one_side})[0][2], "16.13 down, missing up")
        unmeasured = dict(run, params={k: v for k, v in run["params"].items() if k != "reorderedPct"})
        self.assertEqual(self.regenerate.reorder_rows({"x": unmeasured})[0][2], "missing")
        self.assertEqual(self.regenerate.reorder_rows(self.runs), [], "in-order hosts: no table")
        self.assertIn("### Jitter with reordering", self.regenerate.tables(dict(self.runs, **runs)))

    def test_isolation_rows_for_the_healthy_group(self):
        rows = self.regenerate.isolation_rows(self.runs)
        self.assertEqual({(r[2], r[3], r[6]) for r in rows}, {("healthy-mixed", "inputP99", "yes"), ("healthy-mixed", "gapP99", "yes")})

    def test_memory_rows_apply_the_leak_check_against_p0(self):
        rows = {r[0]: r for r in self.regenerate.memory_rows(self.runs)}
        self.assertEqual(rows["bo75-r1"][4], "fail", "3 MiB/s is above P0's 0 + 1 MiB/s")
        self.assertEqual(rows["p0-r1"][4], "pass")

    def test_tables_render(self):
        text = self.regenerate.tables(self.runs)
        for heading in ("### Recovery", "### Per-session recovery", "### Closes and server causes", "### Isolation", "### Memory"):
            self.assertIn(heading, text)


if __name__ == "__main__":
    unittest.main()
