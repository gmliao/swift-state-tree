#!/usr/bin/env python3
"""Tests for the sweep driver: plan.py, calibration.py, calibrate.py, stopcheck.py, run.sh's dry-run
plan and refusals, and cell.py and run.sh against fakes of impair.sh, the load client, the node
tools and GameServer (Linux: they need `ip netns exec` replaced on PATH and POSIX signals).

Usage: python3 test_topic.py   (the analysis's own tests: python3 -m unittest test_analysis)
"""
import contextlib, gzip, io, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time, unittest
from unittest import mock

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import calibrate, calibration, clientload, plan, regenerate, srpause, srsmoke, stopcheck  # noqa: E402
import cell as cell_mod  # noqa: E402

HEAD_FORM = calibration.wireform.WireForm("messagepack", True, True)
SWEEP_ENV_KEYS = ("CELLS", "REPEATS", "ROOMS", "SR_PAUSE", "CALIBRATION", "RATE", "LIMITS", "JITTER_REORDERS", "REORDERED_PCT",
                  "PATH_INDEX", "FIELD_MERGE", "TRANSPORT_ENCODING", "MODE", "SERVER_CPUS", "CLIENT_CPUS", "OVERWRITE", "BUILD",
                  "GAMESERVER_BIN", "ANALYSIS_PY", "STOPCHECK_PY", "INGEST", "IMPAIR_SH", "LOADTEST_SCRIPT", "NODE_TOOLS", "HEALTH_URL", "START_MARGIN_S", "SCENARIO_OVERRIDE")
SWEEP_ENV_KEYS += tuple(f"{k}_GIVEN" for k in ("CALIBRATION", "GAMESERVER_BIN", "ANALYSIS_PY", "STOPCHECK_PY", "IMPAIR_SH", "SCENARIO_OVERRIDE"))


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in SWEEP_ENV_KEYS}
    env.update(extra)
    return env


def head_calibration(path: pathlib.Path) -> pathlib.Path:
    """A calibration whose runs had the sweep's (HEAD's) wire form."""
    cal = json.loads(json.dumps(calibration.BUILTIN))
    cal.update(name="test-head", commit="49fde351", features=["fieldMerge", "pathIndex"])
    path.write_text(json.dumps(cal))
    return path


def dry_run(cwd=None, **env):
    return subprocess.run(["bash", str(TOPIC / "run.sh")], env=clean_env(**{"DRY_RUN": "1", "RUN_ID": "dry", **env}),
                          capture_output=True, text=True, encoding="utf-8", cwd=cwd)


class RecordedPath(unittest.TestCase):
    def test_inside_the_topic_relative_else_as_given(self):
        import runmeta
        self.assertEqual(runmeta.recorded_path(str(TOPIC / "data" / "c" / "calibration.json"), "/abs/whatever", TOPIC),
                         "data/c/calibration.json")
        self.assertEqual(runmeta.recorded_path("/elsewhere/c.json", "../c.json", TOPIC), "../c.json")
        self.assertEqual(runmeta.recorded_path("/elsewhere/c.json", None, TOPIC), "/elsewhere/c.json")
        self.assertIsNone(runmeta.recorded_path("", "x", TOPIC))


class Plan(unittest.TestCase):
    def test_the_order_is_u_m_the_sr_calibration_then_sr(self):
        order = plan.order()
        self.assertEqual(len(order), 15 + 9 + 1 + 3)
        blocks = [plan.population(c) if c != "SR-CAL" else "SR-CAL" for c, _ in order]
        self.assertEqual(blocks, ["U"] * 15 + ["M"] * 9 + ["SR-CAL"] + ["SR"] * 3)

    def test_each_repeat_starts_with_its_p0_and_rotates_the_rest(self):
        for block in ("U", "M"):
            passes = [plan.rotated(plan.BLOCKS[block], r) for r in plan.REPEATS]
            for p in passes:
                self.assertEqual(p[0], f"{block}-P0")
                self.assertEqual(sorted(p), sorted(plan.BLOCKS[block]))
            # Every non-P0 cell takes a different position in each repeat (when there are enough).
            rest = len(plan.BLOCKS[block]) - 1
            for cell in plan.BLOCKS[block][1:]:
                positions = {p.index(cell) for p in passes}
                self.assertEqual(len(positions), min(rest, 3), (block, cell, passes))

    def test_a_filter_keeps_the_order(self):
        self.assertEqual(plan.order(["SR", "M-COMBO"], [1, 2]), [("M-COMBO", 1), ("M-COMBO", 2), ("SR", 1), ("SR", 2)])
        with self.assertRaises(ValueError):
            plan.order(["U-P1"])

    def test_layouts_groups_and_rosters(self):
        u = plan.instances("U-L5", 300)
        self.assertEqual(u, {"lt-client": {"slots": None, "connections": 1500, "workers": 12, "reconstruct": "0-299:0-1"}})
        m = plan.instances("M-COMBO", 300)
        self.assertEqual(m["lt-client"], {"slots": "0-149:0", "connections": 150, "workers": 2, "reconstruct": "0-149:0"})
        self.assertEqual(m["lt-good"], {"slots": "0-149:1-4,150-299:0-4", "connections": 1350, "workers": 10,
                                        "reconstruct": "0-149:1,150-299:0"})
        # Option A's coverage: every impaired player, one healthy player per mixed room, slot 0 of each
        # healthy room (R = 450); U slots 0-1.
        self.assertEqual(plan.convergence_roster("M-BO75", 300), {"lt-client": {"1": 150}, "lt-good": {"1": 300}})
        self.assertEqual(plan.convergence_roster("U-P0", 300), {"lt-client": {"2": 300}})
        self.assertEqual(plan.convergence_roster("SR", 10), {"lt-client": {"1": 5}, "lt-good": {"1": 10}})
        g = plan.groups("SR", 300, "run")
        self.assertEqual({k: v["target"] for k, v in g.items()}, {"impaired": 150, "healthy-mixed": 600, "healthy-rooms": 750})
        self.assertEqual(g["healthy-mixed"]["lands"][0], "run-room-p5-0")
        self.assertEqual(g["healthy-rooms"]["lands"][0], "run-room-p5-150")
        self.assertTrue(all(name.startswith(regenerate.HEALTHY_GROUPS_PREFIX) for name in g if name != "impaired"))

    def test_scenarios_and_the_slow_readers_pause(self):
        self.assertEqual(plan.scenario_file("U-BO75", 300).name, "impairment-300-bo75.json")
        self.assertEqual(plan.scenario_file("M-COMBO", 10).name, "impairment-10.json")
        with self.assertRaises(ValueError):
            plan.scenario_file("SR-CAL", 10)
        base = json.loads(plan.scenario_file("SR", 300).read_text())
        sr = plan.with_impaired_seconds(base, 123)
        self.assertEqual(sr["impairment"]["impairedSeconds"], 123)
        self.assertEqual(sr["phases"]["preflight"]["durationSeconds"], 15 + 30 + 123 + 90 + 45)


class SyncLagStaleness(unittest.TestCase):
    """The shared check (calibration.rate_staleness): plan.py refuses to plan a rate cell whose
    calibration #344's frames make stale; regenerate.py reports the same numbers."""

    def test_the_builtin_calibration_has_headroom(self):
        for cell in calibration.RATE_CELLS:
            check = calibration.rate_staleness(cell, calibration.BUILTIN["cells"][cell]["rate"], plan.shaped_connections(cell, 300))
            self.assertFalse(check["stale"], check)
            self.assertLess(check["share"], 0.05)

    def test_the_numbers_and_the_refusal(self):
        # M-COMBO at 300 rooms: 150 connections behind the shaped link, 90 B/s each.
        check = calibration.rate_staleness("M-COMBO", "100000bit", 150)
        self.assertEqual((check["p0DownBytesPerS"], check["extraDownBytesPerS"], check["upUnshapedBytesPerS"]), (15625, 13500, 9750))
        self.assertTrue(check["stale"])
        self.assertEqual(check["message"], "recalibrate: #344 frames add 86 % to the calibrated demand")
        self.assertFalse(calibration.rate_staleness("M-COMBO", "1000000bit", 150)["stale"], "8.6 %: under the 20 % bound")
        self.assertEqual(calibration.rate_bytes_per_s("3mbit"), 375_000)

    def test_plan_refuses_a_stale_rate_cell_before_it_is_scheduled(self):
        env = dict(os.environ, RATE="100000bit")
        done = subprocess.run([sys.executable, str(TOPIC / "plan.py"), "order", "--cells", "M-COMBO", "--repeats", "1", "--rooms", "300"],
                              capture_output=True, text=True, env=env)
        self.assertEqual(done.returncode, 2)
        self.assertEqual(done.stdout, "")
        self.assertIn("M-COMBO: recalibrate: #344 frames add 86 % to the calibrated demand", done.stderr)
        ok = subprocess.run([sys.executable, str(TOPIC / "plan.py"), "order", "--cells", "M-COMBO U-P0", "--repeats", "1"],
                            capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "RATE"})
        self.assertEqual(ok.returncode, 0, ok.stderr)


class SyncLagDefaults(unittest.TestCase):
    """cell.py records sync-lag tracking's thresholds and the load client's reconnect timing in
    params: they must be what the server and ws-loadtest actually default to."""
    ROOT = TOPIC.parent.parent

    def test_the_thresholds_match_the_servers_defaults(self):
        import cell
        source = (self.ROOT / "Sources" / "SwiftStateTreeTransport" / "SyncLag.swift").read_text(encoding="utf-8")
        expected = {"resyncAfterMs": r"resyncAfter: Duration = \.seconds\((\d+)\)", "slowConsumerCount": r"slowConsumerCount: Int = (\d+)",
                    "slowConsumerWindowMs": r"slowConsumerWindow: Duration = \.seconds\((\d+)\)",
                    "ackTimeoutMs": r"ackTimeout: Duration = \.seconds\((\d+)\)", "ackFreshnessMs": r"ackFreshness: Duration = \.seconds\((\d+)\)"}
        for key, pattern in expected.items():
            value = int(re.search(pattern, source).group(1))
            self.assertEqual(cell.SYNC_LAG_DEFAULTS[key], value if key == "slowConsumerCount" else value * 1000, key)
        limit = int(re.search(r"snapshotEncodeFailureLimit = (\d+)", source).group(1))
        self.assertEqual(regenerate.UNENCODABLE_FAILURES_PER_CLOSE, limit, "a 4012 follows this many failed snapshot encodes")
        keys = (self.ROOT / "Sources" / "SwiftStateTreeTransport" / "TransportEnvKeys.swift").read_text(encoding="utf-8")
        self.assertEqual(set(cell.SYNC_LAG_ENV), set(re.findall(r'"(SYNC_(?:LAG|ACK)_[A-Z_]+)"', keys)))

    def test_the_sync_lag_keys_are_in_the_shared_server_env_list(self):
        # The shared list (deep-research/serverenv.py) unsets and refuses them for the other topics;
        # this topic records and refuses them itself (meta.syncLagEnv). The two lists must agree.
        import cell
        sys.path.insert(0, str(TOPIC.parent))
        import serverenv
        self.assertEqual(set(cell.SYNC_LAG_ENV) - set(serverenv.SERVER_ENV), set())

    def test_the_reconnect_timing_matches_ws_loadtests_defaults(self):
        import cell
        worker = (self.ROOT / "Examples" / "GameDemo" / "ws-loadtest" / "src" / "worker.ts").read_text(encoding="utf-8")
        self.assertEqual(int(re.search(r"option\.delayMs \?\? (\d+)", worker).group(1)), cell.RECONNECT_DELAY_MS)
        self.assertEqual(int(re.search(r"attemptTimeoutMs \?\? (\d+)", worker).group(1)), cell.RECONNECT_ATTEMPT_TIMEOUT_MS)


class Calibration(unittest.TestCase):
    def test_the_formulas_give_the_11_07_limits(self):
        self.assertEqual(calibration.rate_settings(6304687, 0.5)["limits"], [1050, 10000])
        self.assertEqual(calibration.rate_settings(632378, 0.8)["limits"], [168, 10000])
        self.assertEqual(calibration.rate_settings(1000, 0.5)["limits"][0], 100)

    def test_rate_cells_need_a_calibration_of_the_sweeps_wire_form(self):
        for cell in calibration.RATE_CELLS:
            with self.subTest(cell), self.assertRaisesRegex(calibration.Refused, "no longer throttles"):
                calibration.settings(calibration.BUILTIN, cell, HEAD_FORM)
        # The 11-07 calibration ran before both knobs: it fits a like-for-like sweep.
        old = calibration.wireform.WireForm("messagepack", False, False)
        self.assertEqual(calibration.settings(calibration.BUILTIN, "U-RATE", old)["rate"], "25218749bit")
        cal = json.loads(head_calibration(pathlib.Path(tempfile.mktemp())).read_text())
        self.assertEqual(calibration.settings(cal, "M-COMBO", HEAD_FORM)["limits"], {"down": 168, "up": 10000})

    def test_the_sweeps_form_follows_the_servers_rules(self):
        self.assertEqual(calibration.intended_form({}), HEAD_FORM)
        self.assertEqual(calibration.intended_form({"TRANSPORT_ENCODING": "json"}), calibration.wireform.WireForm("json", False, False))

    def test_the_other_cells_carry_over_and_only_jitter_cells_reorder(self):
        for cell in plan.CELLS:
            if cell in calibration.RATE_CELLS:
                continue
            s = calibration.settings(calibration.BUILTIN, cell, HEAD_FORM)
            self.assertEqual(s["limits"], {"down": 10000, "up": 10000}, cell)
            self.assertNotIn("rate", s)
            self.assertEqual("reorderedPct" in s, cell in calibration.JITTER_CELLS, cell)
        self.assertEqual(calibration.settings(calibration.BUILTIN, "U-D50J10", HEAD_FORM)["reorderedPct"], {"down": 0.614, "up": 0.386})

    def test_a_calibration_file_cant_put_reordering_on_another_cell(self):
        cal = json.loads(json.dumps(calibration.BUILTIN))
        cal["cells"]["U-L5"].update(jitterReorders=True, reorderedPct={"down": 1.0, "up": 1.0})
        self.assertNotIn("reorderedPct", calibration.settings(cal, "U-L5", HEAD_FORM))

    def test_smoke_overrides_are_applied_and_recorded(self):
        o = calibration.overrides_from({"RATE": "1mbit", "LIMITS": "120:9000", "REORDERED_PCT": "1.5:0.5"})
        s = calibration.settings(calibration.BUILTIN, "M-COMBO", HEAD_FORM, o)
        self.assertEqual((s["rate"], s["limits"], s["reorderedPct"]), ("1mbit", {"down": 120, "up": 9000}, {"down": 1.5, "up": 0.5}))
        self.assertEqual(s["calibrationOverrides"]["rate"], "1mbit")
        # A rate override alone doesn't unlock a rate cell: its limit follows from the rate.
        with self.assertRaises(calibration.Refused):
            calibration.settings(calibration.BUILTIN, "U-RATE", HEAD_FORM, {"rate": "1mbit"})
        # Overrides that don't apply to a cell are dropped, not recorded.
        p0 = calibration.settings(calibration.BUILTIN, "U-P0", HEAD_FORM, o)
        self.assertNotIn("rate", p0)
        self.assertEqual(p0["calibrationOverrides"], {"limits": [120, 9000]})


def write_p0_run(d: pathlib.Path, down_bytes_per_s: float, key="messagepack:fieldMerge,pathIndex", commit="a" * 40):
    d.mkdir(parents=True)
    apply_ms, lift_ms = 1_000_000, 1_060_000
    (d / "impairment-timeline.json").write_text(json.dumps([{"action": "apply", "wallMsAfter": apply_ms}, {"action": "lift", "wallMsAfter": lift_ms}]))
    lines = []
    for t in range(apply_ms - 40_000, lift_ms + 100_000, 1000):
        sent = int((t - (apply_ms - 40_000)) / 1000 * down_bytes_per_s)
        lines.append(json.dumps({"t": t, "qdiscs": [{"kind": "netem", "handle": "1:", "parent": "root", "sentBytes": sent},
                                                    {"kind": "netem", "handle": "20:", "parent": "1:2", "sentBytes": 7}]}))
    (d / "netem-backlog.jsonl").write_text("\n".join(lines) + "\n")
    (d / "run.json").write_text(json.dumps({"meta": {"git": {"commit": commit}, "wireForms": {"lt-client": {key: 10}}}}))


class Calibrate(unittest.TestCase):
    def test_rates_and_limits_from_the_p0_runs(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        write_p0_run(tmp / "u", 6304687)
        write_p0_run(tmp / "m", 632378)
        cal = calibrate.build(tmp / "u", tmp / "m", "new")
        self.assertEqual(cal["p0DownstreamBytesPerS"], {"U": 6304687, "M": 632378})
        self.assertEqual((cal["cells"]["U-RATE"]["limits"], cal["cells"]["M-COMBO"]["limits"]), ([1050, 10000], [168, 10000]))
        self.assertEqual((cal["encoding"], cal["features"]), ("messagepack", ["fieldMerge", "pathIndex"]))
        self.assertEqual(cal["cells"]["M-COMBO"]["reorderedPct"], calibration.BUILTIN["cells"]["M-COMBO"]["reorderedPct"])
        # The new calibration unlocks the rate cells for a sweep of its form.
        self.assertIn("rate", calibration.settings(cal, "U-RATE", HEAD_FORM))

    def test_runs_of_different_wire_forms_are_refused(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        write_p0_run(tmp / "u", 1e6)
        write_p0_run(tmp / "m", 1e5, key="messagepack:none")
        with self.assertRaises(SystemExit):
            calibrate.build(tmp / "u", tmp / "m", "new")


class StopCheck(unittest.TestCase):
    def check(self, profile, rows):
        runs = {"r1": {"params": {"profile": profile, "rooms": 300, "population": "U"},
                       "meta": {"git": {"commit": "a" * 40, "dirty": False}, "sendBacklogEnv": {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, "syncLagEnv": {k: None for k in cell_mod.SYNC_LAG_ENV},
                        "clientCpu": {"cpus": 4, "mask": "8-11", "segments": {"baseline": 30.0, "impaired": 31.0, "recovery": 40.0}, "max": 40.0},
                        "clientElu": {"segments": {"baseline": 0.2, "impaired": 0.2, "recovery": 0.3}, "max": 0.3}}}}
        empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
        empty.update(rows)
        with mock.patch.multiple(regenerate, **empty):
            return stopcheck.reasons(runs, "r1")

    def test_missing_stops_any_run(self):
        self.assertTrue(self.check("L5", {"match_rows": lambda runs: [("r1", "L5", "fail (missing: lifecycle log)")]}))

    def test_a_hard_failure_stops_a_p0_only(self):
        rows = {"convergence_rows": lambda runs: [("r1", "P0", 300, "fail (2 mismatched)")]}
        self.assertTrue(self.check("P0", rows))
        self.assertEqual(self.check("L5", rows), [])

    def test_no_control_and_other_runs_rows_dont_stop(self):
        self.assertEqual(self.check("P0", {"session_rows": lambda runs: [("r1", "P0", "fail (no control)"),
                                                                          ("r2", "P0", "fail (missing: x)")]}), [])

    def test_a_p0_per_session_failure_stops_the_sweep(self):
        sessions = {"session_rows": lambda runs: [("r1", "P0", "g", 1493, 0, 7, "gap over its baseline 7", "fail")]}
        self.assertEqual(self.check("P0", sessions), ["session_rows: P0 hard failure: fail"])
        self.assertEqual(self.check("L5", sessions), [], "an impaired cell's per-session failure is its result")
        # A missing input in it stops any run.
        self.assertTrue(self.check("L5", {"session_rows": lambda runs: [("r1", "L5", "g", 0, 0, 0, None, "fail (missing: convergence)")]}))

    def test_main_stops_on_a_p0_per_session_failure(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "results").mkdir()
        run = {"params": {"profile": "P0", "rooms": 300, "population": "U"},
               "meta": {"git": {"commit": "a", "dirty": False},
                        "sendBacklogEnv": {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, "syncLagEnv": {k: None for k in cell_mod.SYNC_LAG_ENV},
                        "clientCpu": {"cpus": 4, "mask": "8-11", "segments": {}, "max": 10.0}, "clientElu": {"segments": {}, "max": 0.1}}}
        (tmp / "results" / "p0-r2.json").write_text(json.dumps(run))
        empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
        empty["session_rows"] = lambda runs: [("p0-r2", "P0", "g", 1493, 0, 7, "silent 7", "fail")]
        out = io.StringIO()
        with mock.patch.multiple(regenerate, **empty), contextlib.redirect_stdout(out):
            self.assertEqual(stopcheck.main(["p0-r2", "--results", str(tmp / "results")]), 1)
        self.assertEqual(out.getvalue(), "stop after p0-r2:\n  session_rows: P0 hard failure: fail\n")
        empty["session_rows"] = lambda runs: [("p0-r2", "P0", "g", 1500, 0, 0, None, "pass")]
        out = io.StringIO()
        with mock.patch.multiple(regenerate, **empty), contextlib.redirect_stdout(out):
            self.assertEqual(stopcheck.main(["p0-r2", "--results", str(tmp / "results")]), 0)
        self.assertEqual(out.getvalue(), "p0-r2: go on\n")

    def test_a_smoke_is_checked_from_its_own_file(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "results").mkdir()
        run = {"params": {"profile": "COMBO"}, "meta": {"git": {"commit": "a", "dirty": True}}}
        (tmp / "result.json").write_text(json.dumps(run))
        empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
        with mock.patch.multiple(regenerate, **empty):
            # Not in results/: without --run-file it isn't found; with it, it's checked and stops.
            self.assertEqual(stopcheck.main(["smoke-r1", "--results", str(tmp / "results")]), 1)
            self.assertEqual(stopcheck.main(["smoke-r1", "--results", str(tmp / "results"), "--run-file", str(tmp / "result.json")]), 1)
            clean = dict(run, meta=dict(run["meta"], git={"commit": "a", "dirty": False},
                                        sendBacklogEnv={"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, syncLagEnv={k: None for k in cell_mod.SYNC_LAG_ENV},
                                        clientCpu={"cpus": 4, "mask": "8-11", "segments": {}, "max": 10.0},
                                        clientElu={"segments": {}, "max": 0.1}))
            (tmp / "result.json").write_text(json.dumps(clean))
            self.assertEqual(stopcheck.main(["smoke-r1", "--results", str(tmp / "results"), "--run-file", str(tmp / "result.json")]), 0)

    def test_a_run_without_results_stops(self):
        self.assertTrue(stopcheck.reasons({}, "r9"))


class Tables(unittest.TestCase):
    """regenerate.py keeps smoke and test-hook runs out of the sweep's tables."""

    def run_(self, **changes):
        run = {"meta": {"git": {"commit": "a" * 40, "dirty": False}, "build": True, "gameserverBin": None,
                        "clientCpu": {"cpus": 4, "mask": "8-11", "segments": {"baseline": 30.0, "impaired": 31.0, "recovery": 40.0}, "max": 40.0},
                        "clientElu": {"segments": {"baseline": 0.2, "impaired": 0.2, "recovery": 0.3}, "max": 0.3},
                        "sendBacklogEnv": {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, "syncLagEnv": {k: None for k in cell_mod.SYNC_LAG_ENV}},
               "params": {"rooms": 300, "population": "U", "profile": "P0"}}
        for key, value in changes.items():
            section, field = key.split("__")
            run[section][field] = value
        return run

    def test_a_sweep_run_is_usable(self):
        self.assertEqual(regenerate.unusable({"r": self.run_()}), [])

    def test_a_dirty_or_unrecorded_tree_is_refused_by_the_tables_and_the_stop_check(self):
        for git in ({"commit": "a" * 40, "dirty": True}, {"commit": "a" * 40, "dirty": None}, None):
            with self.subTest(git):
                run = self.run_(meta__git=git)
                self.assertTrue(any("not from a clean tree" in r for r in regenerate.unusable({"r": run})))
                empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
                with mock.patch.multiple(regenerate, **empty):
                    self.assertTrue(any("not from a clean tree" in r for r in stopcheck.reasons({"r": run}, "r")))

    def test_a_send_backlog_setting_is_refused_by_the_tables_and_the_stop_check(self):
        for backlog in ({"WS_SEND_BACKLOG_MAX_BYTES": "1048576", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, None):
            with self.subTest(backlog):
                run = self.run_(meta__sendBacklogEnv=backlog)
                self.assertIn("send-backlog settings", regenerate.unusable({"r": run})[0])
                empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
                with mock.patch.multiple(regenerate, **empty):
                    self.assertTrue(any("send-backlog" in r for r in stopcheck.reasons({"r": run}, "r")))

    def test_a_sync_lag_setting_is_refused_by_the_tables_and_the_stop_check(self):
        for sync_lag in ({k: ("20000" if k == "SYNC_ACK_TIMEOUT_MS" else None) for k in cell_mod.SYNC_LAG_ENV}, None):
            with self.subTest(sync_lag):
                run = self.run_(meta__syncLagEnv=sync_lag)
                self.assertIn("sync-lag settings", regenerate.unusable({"r": run})[0])
                empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
                with mock.patch.multiple(regenerate, **empty):
                    self.assertTrue(any("sync-lag settings" in r for r in stopcheck.reasons({"r": run}, "r")))

    def test_smoke_hook_and_unbuilt_runs_are_refused(self):
        cases = {"smoke": (self.run_(params__calibrationOverrides={"rate": "1mbit"}), "a smoke run"),
                 "scenario": (self.run_(params__scenarioOverride="/tmp/s.json"), "test hook scenarioOverride"),
                 "margin": (self.run_(params__startMarginS=1), "test hook startMarginS"),
                 "unbuilt": (self.run_(meta__build=False, meta__gameserverBin="/tmp/fake"), "not built by run.sh"),
                 "unknown": (self.run_(meta__build=None), "not built by run.sh")}
        for name, (run, words) in cases.items():
            with self.subTest(name):
                found = regenerate.unusable({name: run})
                self.assertEqual(len(found), 1, found)
                self.assertIn(words, found[0])

    def test_runs_without_a_commit_or_from_two_are_refused(self):
        self.assertIn("r: no commit in its meta", regenerate.unusable({"r": self.run_(meta__git={"commit": None, "dirty": False})}))
        two = {"r1": self.run_(), "r2": self.run_(meta__git={"commit": "b" * 40, "dirty": False})}
        self.assertTrue(any("results from 2 commits" in why for why in regenerate.unusable(two)), regenerate.unusable(two))

    def test_the_tables_open_with_their_provenance(self):
        run = self.run_(meta__swiftVersion="Swift version 6.2.4 (swift-6.2.4-RELEASE)", meta__nodeVersion="v24.22.2",
                        meta__buildConfig="release")
        self.assertEqual(regenerate.provenance_line({"r": run}),
                         f"Provenance, from the results' meta: commit `{'a' * 40}`, clean tree; Swift 6.2.4; Node v24.22.2; build release.")

    def test_regenerate_refuses_them_before_any_table(self):
        with mock.patch.object(regenerate, "load_runs", lambda: {"r": self.run_(params__calibrationOverrides={"rate": "1mbit"})}):
            with mock.patch.object(sys, "argv", ["regenerate.py", "--check"]):
                self.assertEqual(regenerate.main(), 1)


def write_srcal(d: pathlib.Path, closes, target=3, cell="SR-CAL", apply_ms=1_000_000, lift_ms=1_180_000, slow=None, backlog=None,
                resyncs=None, acks=None, rooms=None):
    """An SR-CAL run directory under sync-lag tracking. ``closes`` are (sessionID, playerID, cause,
    t[, code]): a 4010 is ("serverClose", code 4010), the default code. ``slow`` maps each slow
    reader's server playerIDs to its connection key (lt-client's join samples); by default p1..p3
    and their reconnects' p1b.. are k1..k3. ``resyncs`` maps a key to its resync arrivals (by
    default one each, 3.1 s into the pause); ``acks`` a key to its acks sent while paused (by
    default 13): written as each key's client close."""
    d.mkdir(parents=True)
    backlog = backlog or {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}
    params = {"cell": cell} | ({"rooms": rooms} if rooms is not None else {})
    (d / "run.json").write_text(json.dumps({"params": params, "groups": {"impaired": {"target": target}},
                                            "meta": {"sendBacklogEnv": backlog}}))
    slow = slow if slow is not None else {f"p{i}": f"k{i}" for i in (1, 2, 3)} | {f"p{i}b": f"k{i}" for i in (1, 2, 3)}
    keys = sorted(set(slow.values()))
    resyncs = resyncs if resyncs is not None else {k: [apply_ms + 3_100] for k in keys}
    acks = acks if acks is not None else {k: 13 for k in keys}
    (d / "samples" / "lt-client").mkdir(parents=True)
    with gzip.open(d / "samples" / "lt-client" / "w0.ndjson.gz", "wt") as f:
        for player, key in slow.items():
            f.write(json.dumps({"r": "join", "k": key, "t": apply_ms - 10_000, "serverPlayer": player}) + "\n")
        for key, times in resyncs.items():
            for t in times:
                f.write(json.dumps({"r": "resync", "k": key, "t": t, "player": key}) + "\n")
        for key, n in acks.items():
            close = {"r": "close", "key": key, "t": apply_ms + 13_500, "joined": True, "initiator": "server", "code": 1006,
                     "slowReader": True, "readPausedAt": apply_ms, "resyncs": len(resyncs.get(key, [])), "acksSent": (n or 0) + 10}
            if n is not None:
                close["acksSentWhilePaused"] = n
            f.write(json.dumps(close) + "\n")
    (d / "impairment-timeline.json").write_text(json.dumps([
        {"action": "apply", "profile": "SR", "wallMsAfter": apply_ms}, {"action": "lift", "profile": "P0", "wallMsAfter": lift_ms}]))
    lines = []
    for close in closes:
        sid, player, cause, t = close[:4]
        code = close[4] if len(close) > 4 else (4010 if cause == "serverClose" else 4008)
        lines.append({"event": "sessionJoined", "sessionID": sid, "playerID": player, "landID": "l", "wallMs": apply_ms - 10_000})
        lines.append({"event": "sessionClosed", "sessionID": sid, "cause": cause, "code": code, "wallMs": t})
    (d / "land-lifecycle.jsonl").write_text("\n".join(json.dumps(l) for l in lines) + "\n")
    return d


def write_load_run(d: pathlib.Path, workers: dict, apply_ms=1_000_000, lift_ms=1_060_000):
    """A run directory with a timeline and loop spans: workers maps "<instance>/<worker>" to a
    function of the span's start (ms) giving (elu, cpuMs or None), one 1 s span each over every segment."""
    d.mkdir(parents=True)
    (d / "impairment-timeline.json").write_text(json.dumps([
        {"action": "apply", "profile": "COMBO", "wallMsAfter": apply_ms}, {"action": "lift", "profile": "P0", "wallMsAfter": lift_ms}]))
    by_instance: dict[str, dict] = {}
    for name, spans in workers.items():
        inst, worker = name.split("/")
        by_instance.setdefault(inst, {})[worker] = spans
    for inst, ws in by_instance.items():
        (d / "samples" / inst).mkdir(parents=True)
        for worker, spans in ws.items():
            with gzip.open(d / "samples" / inst / f"{worker}.ndjson.gz", "wt") as f:
                for t in range(apply_ms - 30_000, lift_ms + 90_000, 1000):
                    elu, cpu = spans(t)
                    r = {"r": "loop", "from": t, "to": t + 1000, "elu": elu}
                    if cpu is not None:
                        r["cpuMs"] = cpu
                    f.write(json.dumps(r) + "\n")
    return d


class ClientLoad(unittest.TestCase):
    """clientload.py: the client's own CPU demand and worker ELU per segment, and the one rule."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_workers_are_processes_their_cpu_adds_up_once(self):
        # Three worker processes over two instances: 400 + 300 + 300 ms per second on 4 CPUs is 25 %.
        d = write_load_run(self.tmp / "a", {"lt-client/w0": lambda t: (0.3, 400), "lt-good/w0": lambda t: (0.2, 300),
                                            "lt-good/w1": lambda t: (0.2, 300)})
        cpu, elu, missing = clientload.measure(d, {"lt-client": 1, "lt-good": 2}, "8-11")
        self.assertEqual(missing, [])
        self.assertEqual(cpu["segments"], {"baseline": 25.0, "impaired": 25.0, "recovery": 25.0})
        self.assertEqual((cpu["cpus"], cpu["max"]), (4, 25.0))
        # The same CPU over twice the workers is the same demand, never N times it.
        e = write_load_run(self.tmp / "b", {f"lt-good/w{i}": (lambda t: (0.1, 250)) for i in range(4)})
        self.assertEqual(clientload.measure(e, {"lt-good": 4}, "8-11")[0]["max"], 25.0)
        self.assertEqual(elu["max"], 0.3)
        self.assertEqual(clientload.failures({"clientCpu": cpu, "clientElu": elu}), [])

    def test_the_recovery_segment_alone_can_breach(self):
        apply_ms, lift_ms = 1_000_000, 1_060_000
        d = write_load_run(self.tmp / "a", {"lt-client/w0": lambda t: (0.3, 3000 if t >= lift_ms else 400)})
        cpu, elu, _ = clientload.measure(d, {"lt-client": 1}, "8-11")
        self.assertEqual((cpu["segments"]["impaired"], cpu["segments"]["recovery"]), (10.0, 75.0))
        found = clientload.failures({"clientCpu": cpu, "clientElu": elu})
        self.assertTrue(any(f.startswith("workers' CPU demand 75.0 %") for f in found), found)

    def test_a_span_across_an_edge_counts_by_its_overlap(self):
        d = self.tmp / "a"
        write_load_run(d, {"lt-client/w0": lambda t: (0.2, 0)})
        # One extra span of 1000 ms CPU straddling the apply, half in each segment.
        # Appended to the one worker's own file (its other spans carry no CPU time).
        p = d / "samples" / "lt-client" / "w0.ndjson.gz"
        rows = gzip.open(p, "rt").read()
        with gzip.open(p, "wt") as f:
            f.write(rows + json.dumps({"r": "loop", "from": 999_500, "to": 1_000_500, "elu": 0.2, "cpuMs": 1000}) + "\n")
        cpu, _, _ = clientload.measure(d, {"lt-client": 1}, "8")
        self.assertEqual((cpu["segments"]["baseline"], cpu["segments"]["impaired"]), (round(500 * 100 / 30_000, 1), round(500 * 100 / 60_000, 1)))

    def test_over_100_percent_is_broken_and_unmeasurable_is_missing(self):
        d = write_load_run(self.tmp / "a", {"lt-client/w0": lambda t: (0.3, 5000)})
        cpu, elu, _ = clientload.measure(d, {"lt-client": 1}, "8-11")
        self.assertEqual(cpu["max"], 125.0)
        self.assertIn("over 100 %, the measurement is broken", clientload.failures({"clientCpu": cpu, "clientElu": elu})[0])
        # Unpinned: no mask, no demand.
        self.assertIsNone(clientload.measure(d, {"lt-client": 1}, "")[0])
        # Spans without CPU time (an older client).
        old = write_load_run(self.tmp / "b", {"lt-client/w0": lambda t: (0.3, None)})
        self.assertIsNone(clientload.measure(old, {"lt-client": 1}, "8-11")[0])
        self.assertTrue(clientload.failures({"clientCpu": None, "clientElu": elu})[0].startswith("workers' CPU demand missing"))
        # No spans in a segment: neither figure.
        gap = write_load_run(self.tmp / "c", {"lt-client/w0": lambda t: (0.3, 100)}, lift_ms=1_060_000)
        for p in (gap / "samples" / "lt-client").glob("*.gz"):
            rows = [json.loads(l) for l in gzip.open(p, "rt") if json.loads(l)["from"] < 1_060_000]
            with gzip.open(p, "wt") as f:
                f.write("".join(json.dumps(r) + "\n" for r in rows))
        cpu, elu, missing = clientload.measure(gap, {"lt-client": 1}, "8-11")
        self.assertEqual((cpu, elu), (None, None))
        self.assertTrue(any("covers 0% of recovery" in m for m in missing), missing)
        self.assertEqual(len(clientload.failures({})), 2)

    def test_a_worker_that_dies_mid_impairment_makes_the_load_missing(self):
        apply_ms = 1_000_000
        d = write_load_run(self.tmp / "a", {"lt-client/w0": lambda t: (0.3, 400), "lt-client/w1": lambda t: (0.3, 400)})
        p = d / "samples" / "lt-client" / "w1.ndjson.gz"
        rows = [json.loads(l) for l in gzip.open(p, "rt") if json.loads(l)["from"] < apply_ms + 20_000]
        with gzip.open(p, "wt") as f:
            f.write("".join(json.dumps(r) + "\n" for r in rows))
        cpu, elu, missing = clientload.measure(d, {"lt-client": 2}, "8-11")
        self.assertEqual((cpu, elu), (None, None))
        self.assertTrue(any(m.startswith("lt-client/w1 covers 33% of impaired") for m in missing), missing)
        self.assertTrue(any(m.startswith("lt-client/w1 covers 0% of recovery") for m in missing), missing)
        found = clientload.failures({"clientCpu": cpu, "clientElu": elu, "clientLoadMissing": missing})
        self.assertTrue(found[0].startswith("client load missing: lt-client/w1"), found)

    def test_a_worker_missing_from_the_start_makes_the_load_missing(self):
        # Configured with 3 workers; only w0 and w1 wrote spans.
        d = write_load_run(self.tmp / "a", {"lt-good/w0": lambda t: (0.3, 400), "lt-good/w1": lambda t: (0.3, 400)})
        cpu, elu, missing = clientload.measure(d, {"lt-good": 3}, "8-11")
        self.assertEqual((cpu, elu), (None, None))
        self.assertEqual(sorted(missing), [f"lt-good/w2 covers 0% of {seg}" for seg in ("baseline", "impaired", "recovery")])
        # The same files measured against their real count are complete.
        self.assertEqual(clientload.measure(d, {"lt-good": 2}, "8-11")[2], [])
        # Spans from a worker beyond the configured count: the configuration doesn't match the run.
        cpu, _, missing = clientload.measure(d, {"lt-good": 1}, "8-11")
        self.assertIsNone(cpu)
        self.assertEqual(missing, ["lt-good/w1: spans from a worker the instance wasn't configured with"])

    def test_worker_elu_is_a_time_weighted_mean_per_segment(self):
        apply_ms = 1_000_000
        # One worker busy at 0.9 for 10 s of the 60 s impaired segment, 0.4 otherwise: mean 0.483.
        d = write_load_run(self.tmp / "a", {"lt-client/w0": lambda t: (0.9 if apply_ms <= t < apply_ms + 10_000 else 0.4, 100)})
        cpu, elu, _ = clientload.measure(d, {"lt-client": 1}, "8-11")
        self.assertEqual(elu["segments"]["impaired"], round((10 * 0.9 + 50 * 0.4) / 60, 3))
        self.assertEqual(clientload.failures({"clientCpu": cpu, "clientElu": elu}), [])
        hot = write_load_run(self.tmp / "b", {"lt-client/w0": lambda t: (0.2, 100), "lt-good/w0": lambda t: (0.6, 100)})
        cpu, elu, _ = clientload.measure(hot, {"lt-client": 1, "lt-good": 1}, "8-11")
        self.assertIn("client worker ELU 0.6", clientload.failures({"clientCpu": cpu, "clientElu": elu})[0])

    def test_the_tables_and_the_stop_check_apply_the_same_rule(self):
        bad = {"git": {"commit": "a" * 40, "dirty": False}, "clientCpu": {"cpus": 4, "mask": "8-11", "segments": {"baseline": 30.0, "impaired": 30.0, "recovery": 71.0}, "max": 71.0},
               "clientElu": {"segments": {"baseline": 0.2, "impaired": 0.2, "recovery": 0.2}, "max": 0.2},
               "build": True, "sendBacklogEnv": {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}, "syncLagEnv": {k: None for k in cell_mod.SYNC_LAG_ENV}}
        run = {"meta": bad, "params": {"rooms": 300, "population": "U", "profile": "L5"}}
        self.assertTrue(any("71.0 %" in r for r in regenerate.unusable({"r": run})))
        empty = {name: (lambda runs: []) for name in stopcheck.ROW_TABLES}
        with mock.patch.multiple(regenerate, **empty):
            self.assertTrue(any("71.0 %" in r for r in stopcheck.reasons({"r": run}, "r")))


class SrPause(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_the_slowest_4010_plus_10_s(self):
        d = write_srcal(self.tmp / "ok", [
            ("s1", "p1", "serverClose", 1_000_000 + 13_000),          # 4010 at 13.0 s
            ("s2", "p2", "serverClose", 1_000_000 + 13_400),          # 13.4 s, the slowest
            ("s3", "p3", "serverClose", 1_000_000 + 13_200),
            ("s4", "p2b", "serverClose", 1_000_000 + 90_000),         # k2's reconnect: not its first close
            ("s5", "p9", "clientClose", 1_000_000 + 1_000)])          # not a server close
        seconds, basis = srpause.pause_seconds(d)
        self.assertEqual(seconds, 14 + 10)
        self.assertEqual((basis["maxPauseTo4010Ms"], basis["minPauseTo4010Ms"], basis["maxPauseToFirstResyncMs"]), (13_400, 13_000, 3_100))
        done = subprocess.run([sys.executable, str(TOPIC / "srpause.py"), str(d)], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "24"))
        self.assertIn("pause → first resync (client arrival)", done.stderr)

    def test_each_refusal(self):
        three = [(f"s{i}", f"p{i}", "serverClose", 1_013_200) for i in (1, 2, 3)]
        cases = {
            "no server close": (write_srcal(self.tmp / "a", [("s1", "p1", "clientClose", 1_010_000)]), "no slow reader was closed during the pause"),
            "too few": (write_srcal(self.tmp / "b", [("s1", "p1", "serverClose", 1_013_000)]), "1 slow readers were closed during the pause, the run has 3"),
            "outside the pause": (write_srcal(self.tmp / "c", [("s1", "p1", "serverClose", 1_200_000)]), "no slow reader was closed"),
            "not SR-CAL": (write_srcal(self.tmp / "e", [], cell="SR"), "not the SR calibration"),
            # A slow reader closed by 4011 (its acks went stale), the pong timeout or 4008: not a 4010.
            "a 4011": (write_srcal(self.tmp / "m", three[:2] + [("s3", "p3", "serverClose", 1_010_000, 4011)]),
                       "1 slow reader\\(s\\) closed by unresponsive, not a slow-consumer close \\(4010\\) \\(k3\\)"),
            "a 4008": (write_srcal(self.tmp / "n", three[:2] + [("s3", "p3", "backlogUnwritable", 1_040_000)]),
                       "closed by backlogUnwritable, not a slow-consumer close"),
            "no resync": (write_srcal(self.tmp / "o", three, resyncs={"k1": [1_003_100], "k2": [1_003_100], "k3": []}),
                          "k3: 0 resyncs before its 4010, not exactly 1"),
            "two resyncs": (write_srcal(self.tmp / "p", three, resyncs={"k1": [1_003_100, 1_006_200], "k2": [1_003_100], "k3": [1_003_100]}),
                            "k1: 2 resyncs before its 4010, not exactly 1"),
            "no acks while paused": (write_srcal(self.tmp / "q", three, acks={"k1": 13, "k2": 0, "k3": 13}),
                                     "k2: sent no acks while its reading was paused"),
            "acks not recorded": (write_srcal(self.tmp / "r", three, acks={"k1": 13, "k2": 13, "k3": None}),
                                  "k3: sent no acks while its reading was paused \\(None\\)"),
            "a resync before the apply": (write_srcal(self.tmp / "s", three, resyncs={"k1": [999_000, 1_003_100], "k2": [1_003_100], "k3": [1_003_100]}),
                                          "k1: a resync or its close falls before the apply"),
        }
        cases["a healthy player closed"] = (write_srcal(self.tmp / "h", three + [("s9", "h1", "serverClose", 1_020_000)]),
                                            "not among lt-client's joins .*: a healthy player closed, or a slow reader's join sample missing")
        cases["a duplicate ID beyond the target"] = (write_srcal(self.tmp / "i", three + [("s4", "p4", "serverClose", 1_013_000)],
                                                                 slow={"p1": "k1", "p2": "k2", "p3": "k3", "p4": "k4"}),
                                                     "4 slow readers were closed during the pause, the run has 3")
        cases["a backlog variable set"] = (write_srcal(self.tmp / "j", three, backlog={"WS_SEND_BACKLOG_MAX_BYTES": None,
                                                                                      "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": "10000"}),
                                           "send-backlog settings")
        unrecorded = write_srcal(self.tmp / "k", three)
        edit = json.loads((unrecorded / "run.json").read_text()); edit["meta"].pop("sendBacklogEnv")
        (unrecorded / "run.json").write_text(json.dumps(edit))
        cases["backlog not recorded"] = (unrecorded, "send-backlog settings None")
        nosamples = write_srcal(self.tmp / "l", three)
        shutil.rmtree(nosamples / "samples")
        cases["no slow-reader samples"] = (nosamples, "no samples/lt-client/")
        missing = write_srcal(self.tmp / "f", [])
        (missing / "impairment-timeline.json").unlink()
        cases["no timeline"] = (missing, "no impairment-timeline.json")
        broken = write_srcal(self.tmp / "g", [])
        (broken / "impairment-timeline.json").write_text(json.dumps([{"action": "apply", "profile": "SR", "wallMsAfter": 1}]))
        cases["one-sided timeline"] = (broken, "unreadable timeline")
        for name, (d, words) in cases.items():
            with self.subTest(name):
                with self.assertRaisesRegex(srpause.Refused, words):
                    srpause.pause_seconds(d)
                done = subprocess.run([sys.executable, str(TOPIC / "srpause.py"), str(d)], capture_output=True, text=True)
                self.assertEqual(done.returncode, 1)
                self.assertEqual(done.stdout, "")


class SrSmoke(unittest.TestCase):
    """srsmoke.py: the 10-room SR smoke (SR_PAUSE 25 s) passes only when every slow reader paused,
    acked while paused, got one resync, was closed with 4010 in the pause and rebuilt by a firstSync
    after that close, by the end of recovery, and no healthy session was resynced or closed.

    As a paused reader really logs them: its resync arrives when its connection closes (after the
    server's close, before its own), and it reconnects about 1 s later, inside the pause."""

    APPLY, LIFT = 1_000_000, 1_025_000

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def smoke(self, name, cell="SR", rooms=10, pause=25, readers=("k1", "k2", "k3"), code=4010, resyncs=1, acks=13,
              stale=(), rebuilt=True, rebuilt_at="pause", recorded=None, healthy_resync=False, healthy_close=False):
        d = self.tmp / name
        (d / "samples" / "lt-client").mkdir(parents=True)
        (d / "samples" / "lt-good").mkdir(parents=True)
        (d / "run.json").write_text(json.dumps({"params": {"cell": cell, "rooms": rooms, "slowReadS": pause},
                                                "groups": {"impaired": {"target": len(readers)}}}))
        (d / "impairment-timeline.json").write_text(json.dumps([
            {"action": "apply", "profile": "SR", "wallMsAfter": self.APPLY}, {"action": "lift", "profile": "P0", "wallMsAfter": self.LIFT}]))
        life, slow = [], []
        for i, key in enumerate(readers):
            sid, player = f"s{i}", f"p{i}"
            closed_at = self.APPLY + 13_200
            life += [{"event": "sessionJoined", "sessionID": sid, "playerID": player, "landID": "l", "wallMs": self.APPLY - 10_000},
                     {"event": "sessionClosed", "sessionID": sid, "cause": "serverClose", "code": code, "wallMs": closed_at}]
            slow.append({"r": "join", "k": key, "t": self.APPLY - 10_000, "land": "l", "player": key, "serverPlayer": player})
            client_closed = closed_at + 700
            slow += [{"r": "resync", "k": key, "t": closed_at + 600 + n, "player": key} for n in range(resyncs)]
            close = {"r": "close", "key": key, "t": client_closed, "joined": True, "initiator": "server", "code": code,
                     "slowReader": True, "readPausedAt": self.APPLY, "acksSentWhilePaused": acks,
                     "resyncs": resyncs if recorded is None else recorded}
            if key in stale:
                close.update(initiator="client", cause="stale")
            slow.append(close)
            if rebuilt:
                first_sync = {"pause": client_closed + 1_000, "lift": self.LIFT + 2_000, "before": client_closed - 100}[rebuilt_at]
                slow.append({"r": "reconnect", "k": key, "key": key, "closedAt": client_closed, "outcome": "recovered",
                             "firstSyncAt": first_sync})
        good = [{"r": "join", "k": "g1", "t": self.APPLY - 10_000, "land": "l", "player": "g1"}]
        if healthy_resync:
            good.append({"r": "resync", "k": "g1", "t": self.APPLY + 5_000, "player": "g1"})
        if healthy_close:
            good.append({"r": "close", "key": "g1", "t": self.APPLY + 5_000, "joined": True, "initiator": "server", "code": 4010})
        for inst, recs in (("lt-client", slow), ("lt-good", good)):
            with gzip.open(d / "samples" / inst / "w0.ndjson.gz", "wt") as f:
                f.write("".join(json.dumps(r) + "\n" for r in recs))
        (d / "land-lifecycle.jsonl").write_text("".join(json.dumps(l) + "\n" for l in life))
        return d

    def test_passes_with_one_resync_then_4010_and_a_rebuild(self):
        d = self.smoke("ok")
        self.assertEqual(srsmoke.failures(d)[0], [])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(srsmoke.main([str(d)]), 0)
        self.assertIn("3 slow readers: 1 resync each, then 4010 13200–13200 ms into the pause", out.getvalue())

    def test_a_resync_logged_after_the_server_close_counts_and_a_rebuild_inside_the_pause_passes(self):
        # The fixture's default is the export's shape: the resync logged 600 ms after the 4010 (when
        # the paused connection closed), the reconnect 1 s after the close, inside the pause.
        failed, seen = srsmoke.failures(self.smoke("export-shape"))
        self.assertEqual((failed, seen["slowReaders"]), ([], 3))
        self.assertEqual(srsmoke.failures(self.smoke("after-lift", rebuilt_at="lift"))[0], [], "a rebuild after the lift passes too")

    def test_fails_on_each_broken_link(self):
        cases = {
            "a 4011, not 4010": (self.smoke("a", code=4011), "closed by unresponsive .* not a 4010 during the pause"),
            "a 4008": (self.smoke("b", code=4008), "closed by serverClose .* not a 4010"),
            "no resync": (self.smoke("c", resyncs=0), "0 resyncs, not 1"),
            "two resyncs": (self.smoke("d", resyncs=2), "2 resyncs, not 1"),
            "no acks while paused": (self.smoke("e", acks=0), "no acks while paused"),
            "stale during the pause": (self.smoke("f", stale=("k2",)), "slow reader k2: .*closed by the stale check during the pause"),
            "not rebuilt": (self.smoke("g", rebuilt=False), "not rebuilt by a firstSync after its close"),
            "a firstSync before its close": (self.smoke("g2", rebuilt_at="before"), "not rebuilt by a firstSync after its close"),
            "resync lines against the close record": (self.smoke("g3", recorded=2),
                                                      "1 resync lines in the connection open at the apply, its close record counts 2"),
            "a healthy session resynced": (self.smoke("h", healthy_resync=True), "1 healthy session\\(s\\) resynced \\(g1\\)"),
            "a healthy session closed": (self.smoke("i", healthy_close=True), "1 healthy session\\(s\\) closed by the server"),
            "the calibration": (self.smoke("j", cell="SR-CAL"), "cell 'SR-CAL': the smoke is SR"),
            "300 rooms": (self.smoke("k", rooms=300), "300 rooms: the smoke runs at 10"),
            "another pause": (self.smoke("l", pause=24), "pause 24 s: the smoke fixes SR_PAUSE at 25"),
        }
        for name, (d, pattern) in cases.items():
            with self.subTest(name):
                failed, _ = srsmoke.failures(d)
                self.assertTrue(any(re.search(pattern, f) for f in failed), failed)
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(srsmoke.main([str(d)]), 1)


class DryRunPlan(unittest.TestCase):
    def full(self):
        cal = head_calibration(pathlib.Path(tempfile.mktemp(suffix=".json")))
        self.addCleanup(cal.unlink)
        done = dry_run(CALIBRATION=str(cal), SR_PAUSE="100")
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def runs(self, out):
        """{run id: its dry-run lines}."""
        runs, current = {}, None
        for line in out.splitlines():
            if line.startswith("== "):
                current = line[3:]
                runs[current] = []
            elif current is not None:
                runs[current].append(line)
        return runs

    def test_every_run_in_order_with_its_steps(self):
        out = self.full()
        runs = self.runs(out)
        expected = [plan.run_id("dry", c, r) for c, r in plan.order()]
        self.assertEqual(list(runs), expected)
        for rid, lines in runs.items():
            steps = [re.match(r"\+ step (\w+):", l).group(1) for l in lines if l.startswith("+ step ")]
            self.assertEqual(steps[:6], ["timewait", "sockets", "setup", "server", "samplers", "schedule"], rid)
            self.assertEqual(steps[6:], ["clients"] * (len(steps) - 11) + ["converge", "finish", "teardown", "record", "record"], rid)
            ingested = any("analysis.py ingest" in l for l in lines)
            self.assertEqual(ingested, not rid.endswith("SR-CAL"), rid)

    def test_per_cell_settings(self):
        runs = self.runs(self.full())
        for rid, lines in runs.items():
            text = "\n".join(lines)
            cell = next(c for c in sorted(plan.CELLS, key=len, reverse=True) if f"-{c}" in rid)
            params = json.loads(re.search(r"run\.json params (\{.*\})", text).group(1))
            with self.subTest(rid):
                self.assertEqual("--with-good" in text, plan.population(cell) in ("M", "SR"))
                self.assertEqual("rate" in params, cell in calibration.RATE_CELLS)
                self.assertEqual("--rate " in text, cell in calibration.RATE_CELLS)
                self.assertEqual("reorderedPct" in params, cell in calibration.JITTER_CELLS)
                self.assertIn(f"schedule {plan.profile(cell)} ", text)
                self.assertEqual("--slow-read" in text, plan.profile(cell) == "SR")
                self.assertEqual(params["convergenceRoster"], plan.convergence_roster(cell, 300))
                impaired = {"BO75": 75, "SR": 100}.get(plan.profile(cell), 60)
                if cell == "SR-CAL":
                    impaired = 180
                self.assertEqual(params["impairedSeconds"], impaired)
                self.assertIn(f"--for {impaired} ", text)
                if plan.profile(cell) == "SR":
                    self.assertIn(f"--slow-read 45:{impaired}", text)
                self.assertEqual(text.count("ip netns exec "), len(plan.instances(cell, 300)))
                self.assertEqual(text.count("--input-latency-min-seen 0 "), len(plan.instances(cell, 300)))
                for spec in plan.instances(cell, 300).values():
                    self.assertIn(f"--reconstruct-slots {spec['reconstruct']}", text)

    def test_the_smoke_line(self):
        done = dry_run(ROOMS="10", CELLS="M-COMBO", REPEATS="1", RATE="4047216bit", LIMITS="168:10000")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(list(self.runs(done.stdout)), ["dry-M-COMBO-r1"])
        self.assertIn('"calibrationOverrides": {"limits": [168, 10000], "rate": "4047216bit"}', done.stdout)
        self.assertIn('"rooms": 10', done.stdout)

    def test_refusals_stop_with_a_named_reason(self):
        sr = dry_run(CELLS="SR", REPEATS="1")
        self.assertEqual(sr.returncode, 2)
        self.assertIn("SR_PAUSE is required", sr.stderr)
        rate = dry_run(CELLS="U-RATE", REPEATS="1")
        self.assertEqual(rate.returncode, 1)
        self.assertIn("no longer throttles", rate.stderr)
        self.assertIn("STOPPED at dry-U-RATE-r1: refused", rate.stderr)
        for env in ({"ROOMS": "100"}, {"CELLS": "U-P1"}, {"REPEATS": "4"}, {"MODE": "x"}, {"SR_PAUSE": "1m"}, {"PATH_INDEX": "off"}, {"INGEST": "2"},
                    {"MODE": "calibrate", "CELLS": "U-P0"}, {"RUN_ID": "a/b"}):
            with self.subTest(env):
                self.assertEqual(dry_run(**env).returncode, 2)

    def test_cell_py_alone_refuses_sr_without_its_pause(self):
        done = subprocess.run([sys.executable, str(TOPIC / "cell.py"), "SR", "1", "--sweep", "dry", "--server", "x", "--dry-run"],
                              env=clean_env(), capture_output=True, text=True)
        self.assertEqual(done.returncode, 3)
        self.assertIn("SR needs SR_PAUSE", done.stderr)

    def test_a_relative_calibration_is_read_from_the_callers_directory(self):
        # The host's step 2 from the README: CALIBRATION=data/<CAL>/calibration.json, relative to
        # where run.sh was started; cell.py runs from Examples/GameDemo, so run.sh resolves it first.
        caller = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, caller)
        (caller / "data" / "cal").mkdir(parents=True)
        head_calibration(caller / "data" / "cal" / "calibration.json")
        done = dry_run(cwd=caller, CALIBRATION="data/cal/calibration.json", SR_PAUSE="100")
        self.assertEqual(done.returncode, 0, done.stderr)
        # Every run read the calibration file (named test-head), from Examples/GameDemo.
        self.assertEqual(done.stdout.count("calibration test-head"), 15 + 9 + 1 + 3, done.stdout[-2000:])

    def test_a_missing_file_input_is_refused_before_any_run(self):
        caller = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, caller)
        for key in ("CALIBRATION", "GAMESERVER_BIN", "ANALYSIS_PY", "STOPCHECK_PY", "IMPAIR_SH", "SCENARIO_OVERRIDE"):
            with self.subTest(key):
                done = dry_run(cwd=caller, **{key: "data/none.json"})
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
                self.assertIn(f"{key}: no file data/none.json (resolved from {caller.resolve()})", done.stderr)
                self.assertNotIn("== dry-", done.stdout)

    def test_the_planned_stop_before_sr_is_exit_3_and_a_failure_before_it_is_1(self):
        # Step 2 of the host procedure: the whole plan, then the planned stop at SR.
        cal = head_calibration(pathlib.Path(tempfile.mktemp(suffix=".json")))
        self.addCleanup(cal.unlink)
        planned = dry_run(CALIBRATION=str(cal))
        self.assertEqual(planned.returncode, 3, planned.stderr)
        runs = list(self.runs(planned.stdout))
        self.assertEqual(runs[-2:], ["dry-SR-CAL", "dry-SR-r1"])
        self.assertEqual(len(runs), 15 + 9 + 2)
        # A failure before SR is still 1 (the built-in calibration refuses U-RATE).
        failed = dry_run()
        self.assertEqual(failed.returncode, 1)
        self.assertNotIn("== dry-SR-r1", failed.stdout)

    def test_cells_naming_sr_without_its_pause_is_a_bad_option(self):
        for cells in ("SR", "M-BO75 SR", "SR-CAL SR"):
            with self.subTest(cells):
                done = dry_run(CELLS=cells, REPEATS="1")
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
                self.assertIn("SR_PAUSE is required with CELLS=SR", done.stderr)
                self.assertNotIn("== ", done.stdout)
        # SR-CAL alone needs no pause.
        self.assertEqual(dry_run(CELLS="SR-CAL").returncode, 0)

    def test_calibrate_mode_runs_both_p0s_then_calibrate(self):
        done = dry_run(MODE="calibrate")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(list(self.runs(done.stdout)), ["dry-U-P0-r0", "dry-M-P0-r0"])
        self.assertNotIn("analysis.py ingest", done.stdout)
        self.assertIn("calibrate.py --u-p0", done.stdout)


FAKE_IP = """#!/bin/sh
[ "$1 $2" = "netns list" ] && exit 0
if [ "$1 $2" = "netns exec" ]; then shift 3; exec "$@"; fi
exit 0
"""
FAKE_IMPAIR = r"""#!/usr/bin/env bash
echo "$1" >> "$FAKE_TRACE"
cmd="$1"; shift
case "$cmd" in
  setup) [ "${FAKE_FAIL:-}" = setup ] && exit 1; exit 0 ;;
  teardown) exit 0 ;;
  sample-backlog)
    out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
    trap 'exit 0' TERM INT
    while true; do echo '{"t": 0, "qdiscs": []}' >> "$out"; sleep 0.2; done ;;
  schedule)
    profile="$1"; shift; at=""; for_s=""; tl=""
    while [ $# -gt 0 ]; do case "$1" in --at) at="$2"; shift 2 ;; --for) for_s="$2"; shift 2 ;; --timeline) tl="$2"; shift 2 ;; *) shift ;; esac; done
    python3 - "$profile" "$at" "$for_s" "$tl" <<'PY'
import json, sys, time
profile, at, for_s, tl = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
time.sleep(max(0, at / 1000 - time.time()))
entries = [{"action": "apply", "profile": profile, "wallMsAfter": int(time.time() * 1000)}]
json.dump(entries, open(tl, "w"))
time.sleep(for_s)
entries.append({"action": "lift", "profile": "P0", "wallMsAfter": int(time.time() * 1000)})
json.dump(entries, open(tl, "w"))
PY
    ;;
esac
"""
FAKE_CLIENT = r"""#!/usr/bin/env bash
# Stands in for run-ws-loadtest.sh: runs the scenario's first phase from --start-at, writes a report.
args=("$@")
python3 - "${args[@]}" <<'PY'
import json, os, pathlib, sys, time
argv = sys.argv[1:]
opt = {argv[i]: argv[i + 1] for i in range(len(argv) - 1) if argv[i].startswith("--")}
out = pathlib.Path(opt["--output-dir"]); out.mkdir(parents=True, exist_ok=True)
pathlib.Path(opt["--samples-dir"]).mkdir(parents=True, exist_ok=True)
scenario = json.loads(pathlib.Path(opt["--scenario"]).read_text())
start = int(opt["--start-at"]) / 1000
if os.environ.get("FAKE_CLIENT") == "early-exit":
    sys.exit(4)
time.sleep(max(0, start + scenario["phases"]["preflight"]["durationSeconds"] - time.time()))
# Loop spans with CPU time, one per second over the phase, as a worker writes them.
import gzip
for w in range(int(opt.get("--workers", "1"))):
    with gzip.open(pathlib.Path(opt["--samples-dir"]) / f"w{w}.ndjson.gz", "wt") as f:
        for i in range(scenario["phases"]["preflight"]["durationSeconds"]):
            f.write(json.dumps({"r": "loop", "from": int(start * 1000) + i * 1000, "to": int(start * 1000) + (i + 1) * 1000,
                                "elu": 0.2, "cpuMs": 100}) + "\n")
report = {"phases": [{"name": "preflight", "phaseTotals": {"stateUpdateFeatures": {"messagepack:fieldMerge,pathIndex": 7}},
                      "measurement": {"clientLoopDelay": {"p99Ms": {"max": 1.5}}}}]}
(out / "ws-loadtest-1.json").write_text(json.dumps(report))
PY
"""
FAKE_CONVERGE = """const fs = require("fs");
const a = process.argv.slice(2);
fs.writeFileSync(a[a.indexOf("--out") + 1], JSON.stringify({ totals: {}, controls: a.filter((x, i) => a[i - 1] === "--control") }));
"""
FAKE_SOCKSTAT = """const fs = require("fs");
const a = process.argv.slice(2);
const out = a[a.indexOf("--out") + 1];
setInterval(() => fs.appendFileSync(out, "{}\\n"), 200);
process.on("SIGTERM", () => process.exit(0));
"""
FAKE_SERVER = """#!/usr/bin/env python3
import http.server, os, signal, sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["FAKE_PORT"])), H).serve_forever()
"""
TINY_SCENARIO = {
    "serverUrl": "ws://10.200.0.1:8080/game/hero-defense",
    "impairment": {"warmupSeconds": 1, "baselineSeconds": 1, "impairedSeconds": 1, "recoverySeconds": 1, "tailSeconds": 2},
    "phases": {"preflight": {"durationSeconds": 6}, "steady": {"durationSeconds": 1}, "postflight": {"durationSeconds": 1}},
}


@unittest.skipUnless(sys.platform.startswith("linux"), "the fakes need Linux")
class Fakes(unittest.TestCase):
    """cell.py and run.sh for real, with fake impair.sh, client, node tools and server."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("ip", FAKE_IP), ("ss", "#!/bin/sh\nexit 0\n"), ("tc", "#!/bin/sh\nexit 0\n"), ("swift", "#!/bin/sh\nexit 0\n")):
            (bin_dir / name).write_text(body)
        tools = self.tmp / "tools"
        tools.mkdir()
        (tools / "converge-main.js").write_text(FAKE_CONVERGE)
        (tools / "sockstat-main.js").write_text(FAKE_SOCKSTAT)
        for name, body in (("impair.sh", FAKE_IMPAIR), ("client.sh", FAKE_CLIENT), ("server.py", FAKE_SERVER)):
            (self.tmp / name).write_text(body)
        for f in list(bin_dir.iterdir()) + [self.tmp / "server.py"]:
            f.chmod(0o755)
        (self.tmp / "scenario.json").write_text(json.dumps(TINY_SCENARIO))
        port = 18000 + os.getpid() % 1000
        self.env = clean_env(PATH=f"{bin_dir}:{os.environ['PATH']}", IMPAIR_SH=str(self.tmp / "impair.sh"),
                             LOADTEST_SCRIPT=str(self.tmp / "client.sh"), NODE_TOOLS=str(tools),
                             HEALTH_URL=f"http://127.0.0.1:{port}/schema", FAKE_PORT=str(port), START_MARGIN_S="1",
                             SCENARIO_OVERRIDE=str(self.tmp / "scenario.json"), FAKE_TRACE=str(self.tmp / "trace"),
                             RATE="4047216bit", LIMITS="168:10000")
        self.out_root = self.tmp / "data"

    def cell(self, cell="M-COMBO", **env):
        argv = [sys.executable, str(TOPIC / "cell.py"), cell, "1", "--sweep", "t", "--server", str(self.tmp / "server.py"),
                "--rooms", "10", "--server-cpus", "", "--client-cpus", "", "--out-root", str(self.out_root)]
        done = subprocess.run(argv, env=dict(self.env, **env), capture_output=True, text=True, timeout=90)
        record = json.loads((self.out_root / f"t-{cell}-r1" / "run.json").read_text())
        trace = (self.tmp / "trace").read_text().split() if (self.tmp / "trace").exists() else []
        return done, record, trace

    def test_a_run_goes_through_every_step_and_records_it(self):
        done, record, trace = self.cell()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        steps = re.findall(r"step (\w+)", done.stdout)
        self.assertEqual(steps, ["timewait", "sockets", "setup", "server", "samplers", "schedule", "clients", "converge",
                                 "finish", "teardown", "record"])
        self.assertEqual(trace[0], "setup")
        self.assertEqual(trace[-1], "teardown")
        self.assertIn("schedule", trace)
        out = self.out_root / "t-M-COMBO-r1"
        timeline = json.loads((out / "impairment-timeline.json").read_text())
        self.assertEqual([e["action"] for e in timeline], ["apply", "lift"])
        self.assertTrue((out / "convergence.json").exists())
        conv = json.loads((out / "convergence.json").read_text())
        self.assertEqual(conv["controls"], ["lt-client=/tmp/sst-ctl-lt-client.sock", "lt-good=/tmp/sst-ctl-lt-good.sock"])
        p = record["params"]
        self.assertEqual((p["rate"], p["limits"], p["population"], p["rooms"]), ("4047216bit", {"down": 168, "up": 10000}, "M", 10))
        self.assertEqual(p["convergenceRoster"], {"lt-client": {"1": 5}, "lt-good": {"1": 10}})
        self.assertEqual(p["scenarioOverride"], str(self.tmp / "scenario.json"))
        self.assertTrue(all(g["loopDelayP99Ms"] == 1.5 for g in record["groups"].values()))
        self.assertEqual(record["meta"]["wireForms"], {"lt-client": {"messagepack:fieldMerge,pathIndex": 7},
                                                       "lt-good": {"messagepack:fieldMerge,pathIndex": 7}})
        self.assertEqual(len(record["meta"]["impairSha256"]), 64)
        self.assertNotIn("failure", record["meta"])
        self.assertEqual(record["meta"]["sendBacklogEnv"], {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None})
        self.assertEqual(record["meta"]["syncLagEnv"], {k: None for k in cell_mod.SYNC_LAG_ENV})
        self.assertEqual(p["syncLag"], cell_mod.SYNC_LAG_DEFAULTS)
        self.assertEqual((p["reconnectDelayMs"], p["reconnectAttemptTimeoutMs"]), (1000, 5000))
        # The fake's 6 s run can't cover analysis' 30 s baseline and 90 s recovery: every configured
        # worker (lt-client 2, lt-good 10) is reported short of coverage, and both figures are missing.
        self.assertIsNone(record["meta"]["clientCpu"])
        self.assertIsNone(record["meta"]["clientElu"])
        short = record["meta"]["clientLoadMissing"]
        self.assertEqual({m.split(" ")[0] for m in short if " covers " in m},
                         {f"lt-client/w{i}" for i in range(2)} | {f"lt-good/w{i}" for i in range(10)})
        leaked = self.cell(WS_SEND_BACKLOG_MAX_BYTES="1048576", SYNC_ACK_TIMEOUT_MS="20000", cell="M-BO75")[1]
        self.assertEqual(leaked["meta"]["sendBacklogEnv"]["WS_SEND_BACKLOG_MAX_BYTES"], "1048576")
        self.assertEqual(leaked["meta"]["syncLagEnv"]["SYNC_ACK_TIMEOUT_MS"], "20000")

    def test_a_failed_setup_names_its_step_and_still_tears_down(self):
        done, record, trace = self.cell(FAKE_FAIL="setup")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(record["meta"]["failure"]["step"], "setup")
        self.assertEqual(trace, ["setup", "teardown"])

    def test_a_client_that_exits_early_stops_the_run_and_tears_down(self):
        done, record, trace = self.cell(FAKE_CLIENT="early-exit")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(record["meta"]["failure"]["step"], "clients")
        self.assertEqual(trace[-1], "teardown")
        self.assertEqual(record["meta"]["steps"]["server"]["exitCode"] is not None, True)

    def sweep(self, run_id, cwd=None, **env):
        self.addCleanup(lambda: [shutil.rmtree(p, True) for p in (TOPIC / "data").glob(f"{run_id}*")])
        self.addCleanup(lambda: [p.unlink() for p in (TOPIC / "results").glob(f"{run_id}*.json")])
        full = {**self.env, "BUILD": "0", "GAMESERVER_BIN": str(self.tmp / "server.py"), "SERVER_CPUS": "", "CLIENT_CPUS": "",
                "ROOMS": "10", "CELLS": "M-COMBO", "REPEATS": "1", "RUN_ID": run_id, **env}
        return subprocess.run(["bash", str(TOPIC / "run.sh")], env=full, capture_output=True, text=True, timeout=120, cwd=cwd)

    def test_run_sh_stops_naming_the_failed_step(self):
        rid = f"test-stop-{os.getpid()}"
        # A calibration under the topic's data/, given relative to the topic: run.json names it
        # relative to the topic (no checkout path) with its sha256.
        cal_dir = TOPIC / "data" / f"{rid}-cal"
        cal_dir.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, cal_dir, True)
        cal = head_calibration(cal_dir / "calibration.json")
        done = self.sweep(rid, FAKE_FAIL="setup", CALIBRATION=f"data/{rid}-cal/calibration.json", cwd=TOPIC)
        self.assertEqual(done.returncode, 1)
        self.assertIn(f"STOPPED at {rid}-M-COMBO-r1: step setup failed", done.stderr)
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        self.assertTrue(record["cells"][-1]["status"].startswith("stopped: step setup failed"))
        self.assertEqual((record["build"], record["gameserverBin"]), (False, str(self.tmp / "server.py")))
        self.assertEqual(len(record["impairSha256"]), 64)
        import hashlib
        self.assertEqual((record["calibrationFile"], record["calibrationSha256"]),
                         (f"data/{rid}-cal/calibration.json", hashlib.sha256(cal.read_bytes()).hexdigest()))

    def test_run_sh_stops_on_the_stop_check_and_goes_on_without_one(self):
        (self.tmp / "ingest.py").write_text("import sys\nsys.exit(0)\n")
        (self.tmp / "stop.py").write_text("import sys\nprint('stop after it: fail (missing: lifecycle log)')\nsys.exit(1)\n")
        (self.tmp / "go.py").write_text("import sys\nsys.exit(0)\n")
        rid = f"test-stopcheck-{os.getpid()}"
        done = self.sweep(rid, ANALYSIS_PY=str(self.tmp / "ingest.py"), STOPCHECK_PY=str(self.tmp / "stop.py"), REPEATS="1 2")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f"STOPPED at {rid}-M-COMBO-r1: step stopcheck", done.stderr)
        self.assertNotIn(f"== {rid}-M-COMBO-r2", done.stdout)
        rid = f"test-go-{os.getpid()}"
        done = self.sweep(rid, ANALYSIS_PY=str(self.tmp / "ingest.py"), STOPCHECK_PY=str(self.tmp / "go.py"))
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        # The Fakes environment's RATE and LIMITS make it a smoke: ingested into its own directory.
        self.assertEqual(record["cells"][-1]["status"], "ingested-to-data")
        run = json.loads((TOPIC / "data" / f"{rid}-M-COMBO-r1" / "run.json").read_text())
        self.assertEqual(run["meta"]["build"], False)
        self.assertIsNotNone(record["endedAt"])

    def test_run_sh_refuses_a_named_sr_without_its_pause_before_running_anything(self):
        rid = f"test-sr-pause-{os.getpid()}"
        done = self.sweep(rid, CELLS="M-COMBO SR")
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertFalse((TOPIC / "data" / rid).exists())
        self.assertFalse((self.tmp / "trace").exists())

    def stand_ins(self):
        """An ingest that writes `{}` where it's told (--out, else results/<run-id>.json) and logs its
        arguments, and a stop check that logs its own and goes on."""
        (self.tmp / "ingest.py").write_text(
            "import json, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "open(sys.argv[0] + '.log', 'a').write(' '.join(args) + '\\n')\n"
            f"out = pathlib.Path(args[args.index('--out') + 1]) if '--out' in args else pathlib.Path({str(TOPIC / 'results')!r}) / (pathlib.Path(args[1]).name + '.json')\n"
            "out.parent.mkdir(exist_ok=True); out.write_text('{}')\n")
        (self.tmp / "go.py").write_text("import sys\nopen(sys.argv[0] + '.log', 'a').write(' '.join(sys.argv[1:]) + '\\n')\nsys.exit(0)\n")
        return {"ANALYSIS_PY": str(self.tmp / "ingest.py"), "STOPCHECK_PY": str(self.tmp / "go.py")}

    def topic_status(self):
        done = subprocess.run(["git", "status", "--porcelain", "--", str(TOPIC)], capture_output=True, text=True, cwd=TOPIC)
        return [l for l in done.stdout.splitlines() if "__pycache__" not in l]

    def test_the_smoke_line_ingests_into_its_own_directory_and_leaves_the_tree_clean(self):
        # The Fakes environment carries RATE and LIMITS: the documented smoke line's overrides.
        before = self.topic_status()
        rid = f"test-smoke-{os.getpid()}"
        done = self.sweep(rid, **self.stand_ins())
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        run = f"{rid}-M-COMBO-r1"
        self.assertTrue((TOPIC / "data" / run / "result.json").exists())
        self.assertFalse((TOPIC / "results" / f"{run}.json").exists())
        self.assertIn(f"--out {TOPIC / 'data' / run / 'result.json'}", (self.tmp / "ingest.py.log").read_text())
        self.assertIn(f"{run} --run-file {TOPIC / 'data' / run / 'result.json'}", (self.tmp / "go.py.log").read_text())
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        self.assertEqual(record["cells"][-1]["status"], "ingested-to-data")
        self.assertEqual(self.topic_status(), before)

    def test_a_run_without_overrides_still_ingests_into_results(self):
        rid = f"test-sweep-{os.getpid()}"
        self.env.pop("RATE"); self.env.pop("LIMITS")
        self.addCleanup(lambda: (TOPIC / "results" / f"{rid}-M-BO75-r1.json").unlink(missing_ok=True))
        done = self.sweep(rid, CELLS="M-BO75", **self.stand_ins())
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((TOPIC / "results" / f"{rid}-M-BO75-r1.json").exists())
        self.assertNotIn("--out", (self.tmp / "ingest.py.log").read_text())

    def test_ingest_0_skips_ingest_and_the_stop_check(self):
        rid = f"test-noingest-{os.getpid()}"
        done = self.sweep(rid, INGEST="0", **self.stand_ins())
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertFalse((self.tmp / "ingest.py.log").exists())
        self.assertFalse((self.tmp / "go.py.log").exists())
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        self.assertEqual(record["cells"][-1]["status"], "ran-not-ingested")

    def test_run_sh_stops_when_ingest_fails(self):
        rid = f"test-ingest-{os.getpid()}"
        done = self.sweep(rid)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f"STOPPED at {rid}-M-COMBO-r1: step ingest", done.stderr)


if __name__ == "__main__":
    unittest.main()
