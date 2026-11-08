#!/usr/bin/env python3
"""Tests for cells.py, collect.py's draws and histogram, regenerate.py's refusals and run.sh's dry
run, with no build or server.

Usage: python3 test_topic.py
"""
import copy, json, os, pathlib, subprocess, sys, tempfile, unittest
from unittest import mock

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import cells, collect, regenerate  # noqa: E402
sys.path.insert(0, str(TOPIC.parent))
import portable  # noqa: E402


class DrawTests(unittest.TestCase):
    def test_mix_matches_the_swift_side(self):
        # The same values as GameContent's ResolverTestLandTests ("The seeded draws match ...").
        self.assertEqual(collect.join_forms([{"stateUpdateFeatures": {"messagepack:fieldMerge,pathIndex": 3}}, {},
                                             {"stateUpdateFeatures": {"messagepack:fieldMerge,pathIndex": 2, "json:none": 1}}]),
                         {"messagepack:fieldMerge,pathIndex": 5, "json:none": 1})
        self.assertIsNone(collect.join_forms([{}, {}]))
        self.assertEqual(collect.join_forms([{"stateUpdateFeatures": {}}]), {})
        self.assertEqual(collect.mix(1, 0, 3), 0xEAFB_F54A_AF98_7EBF)
        self.assertEqual(collect.mix(1, 1, 3), 0x3FA6_6524_0947_3294)
        self.assertEqual(collect.mix(1, 0, 4), 0x4015_590F_474C_33BD)
        self.assertEqual(collect.mix(7, 12345, 4), 0x21FD_5541_712E_E8D9)
        self.assertEqual(collect.mix(0xFFFF_FFFF_FFFF_FFFF, 3, 3), 0x0ED3_EB7B_2C63_5AC2)

    def test_fail_patterns_match_the_swift_side(self):
        pattern = lambda salt: "".join("x" if collect.fails(1, n, salt, 0.1) else "." for n in range(40))
        self.assertEqual(pattern(collect.JOIN_SALT), "...x............x....x..................")
        self.assertEqual(pattern(collect.LEAVE_SALT), "..x.x....x..x......x....................")

    def test_expected_failures_count_a_lands_first_checks(self):
        self.assertEqual(collect.expected_failures(1, 3, collect.JOIN_SALT, 0.1), 0)
        self.assertEqual(collect.expected_failures(1, 4, collect.JOIN_SALT, 0.1), 1)
        self.assertEqual(collect.expected_failures(1, 40, collect.LEAVE_SALT, 0.1), 5)
        self.assertEqual(collect.expected_failures(1, 40, collect.LEAVE_SALT, 0), 0)


class HistogramTests(unittest.TestCase):
    def test_percentile(self):
        buckets = {49: 50, 50: 40, 51: 9, 120: 1}
        self.assertEqual(collect.percentile(buckets, 0.5), 49)
        self.assertEqual(collect.percentile(buckets, 0.9), 50)
        self.assertEqual(collect.percentile(buckets, 0.99), 51)
        self.assertEqual(collect.percentile(buckets, 1.0), 120)
        self.assertIsNone(collect.percentile({}, 0.5))


class CellTests(unittest.TestCase):
    def test_longest_call(self):
        self.assertEqual(cells.longest_call_ms(cells.CELLS["rate10"]), 200)
        self.assertEqual(cells.longest_call_ms(cells.CELLS["rate10-jitter"]), 400)
        self.assertEqual(cells.longest_call_ms(cells.CELLS["service-deadline"]), 1000)
        self.assertEqual(cells.longest_call_ms(cells.CELLS["framework-deadline"]), 1000)
        # A call that ignores cancellation runs its whole delay past the framework deadline.
        self.assertEqual(cells.longest_call_ms(cells.CELLS["framework-deadline-ignored"]), 1500)

    def test_every_call_ends_inside_the_clients_response_timeout(self):
        # The load client files a call as unanswered after 5 s; every planned call ends sooner.
        for name, c in cells.CELLS.items():
            ends = min(cells.longest_call_ms(c), cells.framework_deadline_ms(c))
            self.assertLess(ends, 4000, name)

    def test_a_held_action_caps_the_offered_rate(self):
        # Each deadline cell's action holds its session up to 1000 ms: they offer 0.5/s, the rest 2/s.
        held = {"service-deadline", "framework-deadline", "framework-deadline-r200",
                "framework-deadline-ignored", "framework-deadline-ignored-r200"}
        for name, c in cells.CELLS.items():
            self.assertEqual(cells.hold_ms(c) >= 500, name in held, name)
            self.assertEqual(c["actions_per_second"], 0.5 if name in held else 2, name)
            cells.check(name, c)
        # The ignored cells hold the session only until the framework deadline gives up.
        self.assertEqual(cells.hold_ms(cells.CELLS["framework-deadline-ignored"]), 1000)
        self.assertEqual(cells.hold_ms(cells.CELLS["rate10-jitter"]), 400)

    def test_the_previous_rate_of_the_deadline_cells_is_refused(self):
        # 2/s against a 1000 ms hold queued a backlog that drained long after the sends stopped.
        for name in ("service-deadline", "framework-deadline", "framework-deadline-ignored-r200"):
            c = dict(cells.CELLS[name], actions_per_second=2)
            with self.assertRaises(ValueError) as cm:
                cells.check(name, c)
            self.assertIn("would queue a backlog", str(cm.exception))
        # Offered = served is refused too: the queue never empties.
        with self.assertRaises(ValueError):
            cells.check("edge", dict(cells.CELLS["framework-deadline"], actions_per_second=1))
        cells.check("under", dict(cells.CELLS["framework-deadline"], actions_per_second=0.99))

    def test_injected_kinds_follow_the_knobs(self):
        for name, c in cells.CELLS.items():
            env = c["env"]
            fails = float(env["RESOLVER_TEST_FAILURE_RATE"]) > 0 or int(env["RESOLVER_TEST_DELAY_MS"]) > int(env["RESOLVER_TEST_DEADLINE_MS"])
            times_out = cells.framework_deadline_ms(c) < int(env["RESOLVER_TEST_DELAY_MS"])
            self.assertEqual("failed" in c["injects"], fails and not times_out, name)
            self.assertEqual("timedOut" in c["injects"], times_out, name)


def line(ts, received, queued=0, actions=0):
    return {"ts": ts, "counters": {"messagesReceived": received, "inboundQueuedMessagesMax": queued, "actions": actions}}


class CellScriptTests(unittest.TestCase):
    def test_quiet_waits_for_no_message_handled_not_for_no_success(self):
        import cell
        # Every action timed out: `actions` reads 0 while the server still handles 20 per second.
        busy = [line(1000 * t, 20) for t in range(10)]
        self.assertIsNone(cell.quiet_point(busy, 0))
        lines = busy + [line(10_000, 3), line(11_000, 0), line(12_000, 0), line(13_000, 0)]
        self.assertEqual(cell.quiet_point(lines, 0), 11_000)
        # One idle interval between two busy ones isn't quiet.
        self.assertIsNone(cell.quiet_point([line(0, 0), line(1000, 5), line(2000, 0)], 0))
        # Lines before the tail don't count.
        self.assertIsNone(cell.quiet_point([line(0, 0), line(1000, 0), line(2000, 4)], 2000))

    def test_queued_max_reads_the_load_up_to_the_quiet_point(self):
        import cell
        lines = [line(0, 20, 9), line(1000, 20, 2), line(2000, 20, 3), line(3000, 0, 7)]
        self.assertEqual(cell.queued_max(lines, 1000, 2000), 3)
        self.assertEqual(cell.queued_max(lines, 0, 3000), 9)
        self.assertEqual(cell.queued_max([], 0, 1), 0)


def result(name, repeat=1):
    c = copy.deepcopy(cells.CELLS[name])
    outcomes = {"applied": 100, "failed": 10 if "failed" in c["injects"] else 0,
                "timedOut": 10 if "timedOut" in c["injects"] else 0, "errored": 0, "unmatched": 0, "answeredAfterPhaseEnd": 0}
    return {
        "meta": {"git_sha": "abc1234", "build_config": "release", "git_dirty": False, "swift_version": "Swift version 6.2.4",
                 "node_version": "v24.22.2", "pin_cpus": "server:0-7 client:8-11"},
        "params": {"cell": name, "repeat": repeat, "rooms": c["rooms"], "pre_s": cells.PRE_S, "steady_s": cells.STEADY_S,
                   "tail_s": cells.TAIL_S, "env": c["env"], "outcome": c["outcome"], "injects": c["injects"]},
        "metrics": {"tick_gap_p50_ms": 50, "tick_gap_p99_ms": 55, "tick_gap_max_ms": 60.0, "ack_p50_ms": 210.0, "ack_p99_ms": 230.0,
                    "tick_advance_p50": 4, "tick_advance_p99": 5,
                    "applied": 100, "failed": outcomes["failed"], "timed_out": outcomes["timedOut"], "abandoned_max": 0,
                    "drain_ms": 1200, "rss_mb_peak": 40},
        "counts": {"outcomes": outcomes, "pendingAtEnd": 0, "abandonedEnd": 0, "expectedJoinFailures": 0,
                   "joinForms": {"messagepack:fieldMerge,pathIndex": 250},
                   "expectedLeaveFailures": 0, "clientLeaves": 0, "serverDroppedLeaves": 0},
        "gates": {"no_errors": True}, "failures": [],
    }


class RegenerateTests(unittest.TestCase):
    def runs(self):
        return [result(name) for name in cells.CELLS]

    def refused(self, runs, text):
        with self.assertRaises(SystemExit) as cm:
            regenerate.check(runs)
        self.assertIn(text, str(cm.exception))

    def edited(self, name, edit):
        runs = self.runs()
        edit(next(r for r in runs if r["params"]["cell"] == name))
        return runs

    def test_a_full_matrix_passes_and_renders(self):
        runs = self.runs()
        regenerate.check(runs)
        md = regenerate.tables(runs)
        self.assertIn("| rate 0.1 | 50 | 55 | 60.0 | 210.0 | 230.0 | 4 | 5 |", md)
        self.assertIn("### Join and leave checks", md)

    def test_refuses_joins_off_the_servers_wire_form_or_without_one(self):
        self.refused(self.edited("rate10", lambda r: r["counts"].update(joinForms={"messagepack:none": 250})),
                     "rate10 rep1: messagepack, pathIndex off, fieldMerge off, intended messagepack, pathIndex on, fieldMerge on")
        self.refused(self.edited("rate10", lambda r: r["counts"].update(
            joinForms={"messagepack:none": 1, "messagepack:fieldMerge,pathIndex": 249})), "rate10 rep1: wire form missing: joins were given different")
        # Not recorded: the commit decides; the fixture's (abc1234) is unknown, so the form is missing.
        self.refused(self.edited("rate10", lambda r: r["counts"].update(joinForms=None)), "rate10 rep1: wire form missing")

    def test_the_results_open_with_their_provenance(self):
        self.assertEqual(regenerate.tables(self.runs()).splitlines()[0],
                         "Provenance, from the results' meta: commit `abc1234`, clean tree; Swift 6.2.4; Node v24.22.2; build release.")

    def test_refuses_results_without_a_commit_or_from_two(self):
        self.refused(self.edited("rate10", lambda r: r["meta"].update(git_sha=None)), "no commit in its meta")
        self.refused(self.edited("rate10", lambda r: r["meta"].update(git_sha="def5678")), "results from 2 commits (abc1234, def5678)")

    def test_overflowing_tick_gaps_read_as_at_least_1000(self):
        runs = self.edited("rate50", lambda r: r["metrics"].update(tick_gap_p99_ms=1000))
        self.assertIn("| rate 0.5 | 50 | ≥1,000 |", regenerate.tables(runs))

    def test_refuses_a_debug_build_or_a_dirty_tree(self):
        self.refused(self.edited("rate10", lambda r: r["meta"].update(build_config="debug")), "not a release build")
        self.refused(self.edited("rate10", lambda r: r["meta"].update(git_dirty=True)), "not from a clean tree")

    def test_refuses_a_failed_gate(self):
        self.refused(self.edited("rate10", lambda r: r["failures"].append("replay: 1 of 50 replays failed")), "gate replay")

    def test_refuses_an_outcome_the_cell_doesnt_inject(self):
        self.refused(self.edited("rate10", lambda r: r["counts"]["outcomes"].update(timedOut=1)), "the cell injects none")
        self.refused(self.edited("rate0", lambda r: r["counts"]["outcomes"].update(failed=3)), "the cell injects none")

    def test_refuses_an_injected_outcome_that_never_came(self):
        self.refused(self.edited("framework-deadline", lambda r: r["counts"]["outcomes"].update(timedOut=0)), "none came")

    def test_refuses_resolvers_still_abandoned_or_requests_pending_at_the_end(self):
        self.refused(self.edited("framework-deadline-ignored", lambda r: r["counts"].update(abandonedEnd=2)), "abandonedResolvers 2")
        self.refused(self.edited("rate10", lambda r: r["counts"].update(pendingAtEnd=1)), "pending at the end")

    def test_refuses_smoke_parameters_and_other_definitions(self):
        self.refused(self.edited("rate10", lambda r: r["params"].update(rooms=2)), "rooms and phases")
        self.refused(self.edited("rate10", lambda r: r["params"].update(steady_s=6)), "rooms and phases")
        self.refused(self.edited("rate10", lambda r: r["params"]["env"].update(RESOLVER_TEST_FAILURE_RATE="0.2")),
                     "another definition")

    def test_refuses_an_unpinned_run(self):
        for pin in ("server:none client:8-11", "server:0-7 client:none", "server:0-7", None):
            with self.subTest(pin):
                self.refused(self.edited("rate10", lambda r, pin=pin: r["meta"].update(pin_cpus=pin)), "rate10 rep1: unpinned")

    def test_refuses_a_missing_cell(self):
        runs = [r for r in self.runs() if r["params"]["cell"] != "leave10"]
        self.refused(runs, "cells missing: leave10")


class CollectPathTests(unittest.TestCase):
    def test_collected_results_carry_no_absolute_path(self):
        # ws-loadtest's toolchain.txt names the server binary by its path in the checkout the sweep ran in.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        raw, results = pathlib.Path(tmp.name) / "raw", pathlib.Path(tmp.name) / "results"
        cell = raw / "s1" / "rate10"
        (cell / "load").mkdir(parents=True)
        (cell / "cell.json").write_text("{}")
        (cell / "load" / "toolchain.txt").write_text(
            "node v24.22.2\nexternal server binary /workspace/checkout/Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer\n")
        record = {"repeat": 1, "runId": "s1", "git": {"commit": "abc1234", "dirty": False}}
        spec = {"actions_per_second": 1, "outcome": None, "injects": [], "env": {}}
        evaluated = ({"cell": "rate10", "rooms": 1, "preS": 1, "steadyS": 1, "tailS": 1, "spec": spec}, {}, {}, {}, [])
        with mock.patch.object(collect, "sweeps", lambda raw: [(raw / "s1" / "run.json", record)]), \
                mock.patch.object(collect, "evaluate", lambda d, record: evaluated):
            collect.collect(raw, results)
        doc = json.loads((results / "rate10-rep1.json").read_text())
        self.assertEqual(portable.absolute_paths(doc), [])
        self.assertIn("external server binary Examples/GameDemo/.build/x86_64-unknown-linux-gnu/release/GameServer",
                      doc["meta"]["client_toolchain"])


class RunShTests(unittest.TestCase):
    def dry(self, **env):
        e = dict(os.environ, DRY_RUN="1", RUN_ID="dry-test", **env)
        return subprocess.run(["bash", str(TOPIC / "run.sh")], capture_output=True, text=True, env=e)

    def test_dry_run_lists_every_cell(self):
        p = self.dry(REPEAT="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("/cell.py "), len(cells.CELLS))
        self.assertEqual(p.stdout.count("converge-main.js"), len(cells.CELLS))
        self.assertEqual(p.stdout.count("--room-slots"), 2 * sum(1 for c in cells.CELLS.values() if c["leavers"]))
        self.assertIn("swift build -c release --product GameServer", p.stdout)
        self.assertIn("swift build -c release --product ReevaluationRunner", p.stdout)

    def test_refusals(self):
        self.assertEqual(self.dry().returncode, 2)
        self.assertEqual(self.dry(REPEAT="1", CELLS="nope").returncode, 2)
        self.assertEqual(self.dry(REPEAT="1", ROOMS="x").returncode, 2)
        for env in (dict(SERVER_CPUS=""), dict(CLIENT_CPUS=""), dict(SERVER_CPUS="", CLIENT_CPUS="")):
            with self.subTest(env):
                p = self.dry(REPEAT="1", **env)
                self.assertEqual(p.returncode, 2)
                self.assertIn("SMOKE=1", p.stderr)
        self.assertEqual(self.dry(REPEAT="1", SMOKE="1", SERVER_CPUS="", CLIENT_CPUS="").returncode, 0)

    def test_pins_server_and_client_apart_by_default(self):
        p = self.dry(REPEAT="1")
        self.assertIn("--server-cpus 0-7 --client-cpus 8-11", p.stdout)


if __name__ == "__main__":
    unittest.main()
