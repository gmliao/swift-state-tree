#!/usr/bin/env python3
"""Tests for the sweep driver: plan.py, calibration.py, calibrate.py, stopcheck.py, run.sh's dry-run
plan and refusals, and cell.py and run.sh against fakes of impair.sh, the load client, the node
tools and GameServer (Linux: they need `ip netns exec` replaced on PATH and POSIX signals).

Usage: python3 test_topic.py   (the analysis's own tests: python3 -m unittest test_analysis)
"""
import json, os, pathlib, re, shutil, subprocess, sys, tempfile, time, unittest
from unittest import mock

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import calibrate, calibration, plan, regenerate, stopcheck  # noqa: E402

HEAD_FORM = calibration.wireform.WireForm("messagepack", True, True)
SWEEP_ENV_KEYS = ("CELLS", "REPEATS", "ROOMS", "SR_PAUSE", "CALIBRATION", "RATE", "LIMITS", "JITTER_REORDERS", "REORDERED_PCT",
                  "PATH_INDEX", "FIELD_MERGE", "TRANSPORT_ENCODING", "MODE", "SERVER_CPUS", "CLIENT_CPUS", "OVERWRITE", "BUILD",
                  "GAMESERVER_BIN", "ANALYSIS_PY", "STOPCHECK_PY", "IMPAIR_SH", "LOADTEST_SCRIPT", "NODE_TOOLS", "HEALTH_URL", "START_MARGIN_S", "SCENARIO_OVERRIDE")


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


def dry_run(**env):
    return subprocess.run(["bash", str(TOPIC / "run.sh")], env=clean_env(**{"DRY_RUN": "1", "RUN_ID": "dry", **env}),
                          capture_output=True, text=True, encoding="utf-8")


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
        self.assertEqual(u, {"lt-client": {"slots": None, "connections": 1500, "workers": 12}})
        m = plan.instances("M-COMBO", 300)
        self.assertEqual(m["lt-client"], {"slots": "0-149:0", "connections": 150, "workers": 1})
        self.assertEqual(m["lt-good"], {"slots": "0-149:1-4,150-299:0-4", "connections": 1350, "workers": 11})
        self.assertEqual(plan.convergence_roster("M-BO75", 300), {"lt-client": {"1": 150}, "lt-good": {"4": 150, "5": 150}})
        self.assertEqual(plan.convergence_roster("U-P0", 300), {"lt-client": {"5": 300}})
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
        runs = {"r1": {"params": {"profile": profile}}}
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

    def test_a_run_without_results_stops(self):
        self.assertTrue(stopcheck.reasons({}, "r9"))


class Tables(unittest.TestCase):
    """regenerate.py keeps smoke and test-hook runs out of the sweep's tables."""

    def run_(self, **changes):
        run = {"meta": {"build": True, "gameserverBin": None}, "params": {"rooms": 300, "population": "U", "profile": "P0"}}
        for key, value in changes.items():
            section, field = key.split("__")
            run[section][field] = value
        return run

    def test_a_sweep_run_is_usable(self):
        self.assertEqual(regenerate.unusable({"r": self.run_()}), [])

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

    def test_regenerate_refuses_them_before_any_table(self):
        with mock.patch.object(regenerate, "load_runs", lambda: {"r": self.run_(params__calibrationOverrides={"rate": "1mbit"})}):
            with mock.patch.object(sys, "argv", ["regenerate.py", "--check"]):
                self.assertEqual(regenerate.main(), 1)


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

    def test_the_smoke_line(self):
        done = dry_run(ROOMS="10", CELLS="M-COMBO", REPEATS="1", RATE="4047216bit", LIMITS="168:10000")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(list(self.runs(done.stdout)), ["dry-M-COMBO-r1"])
        self.assertIn('"calibrationOverrides": {"limits": [168, 10000], "rate": "4047216bit"}', done.stdout)
        self.assertIn('"rooms": 10', done.stdout)

    def test_refusals_stop_with_a_named_reason(self):
        sr = dry_run(CELLS="SR", REPEATS="1")
        self.assertEqual(sr.returncode, 3)
        self.assertIn("STOPPED at dry-SR-r1: SR needs SR_PAUSE", sr.stderr)
        rate = dry_run(CELLS="U-RATE", REPEATS="1")
        self.assertEqual(rate.returncode, 1)
        self.assertIn("no longer throttles", rate.stderr)
        self.assertIn("STOPPED at dry-U-RATE-r1: refused", rate.stderr)
        for env in ({"ROOMS": "100"}, {"CELLS": "U-P1"}, {"REPEATS": "4"}, {"MODE": "x"}, {"SR_PAUSE": "1m"}, {"PATH_INDEX": "off"},
                    {"MODE": "calibrate", "CELLS": "U-P0"}, {"RUN_ID": "a/b"}):
            with self.subTest(env):
                self.assertEqual(dry_run(**env).returncode, 2)

    def test_cell_py_alone_refuses_sr_without_its_pause(self):
        done = subprocess.run([sys.executable, str(TOPIC / "cell.py"), "SR", "1", "--sweep", "dry", "--server", "x", "--dry-run"],
                              env=clean_env(), capture_output=True, text=True)
        self.assertEqual(done.returncode, 3)
        self.assertIn("SR needs SR_PAUSE", done.stderr)

    def test_the_planned_stop_before_sr_is_exit_3_and_a_failure_before_it_is_1(self):
        # Step 2 of the host procedure: everything up to SR, then the planned stop.
        planned = dry_run(CELLS="M-BO75 SR-CAL SR", REPEATS="1")
        self.assertEqual(planned.returncode, 3, planned.stderr)
        self.assertEqual(list(self.runs(planned.stdout)), ["dry-M-BO75-r1", "dry-SR-CAL", "dry-SR-r1"])
        # A failure before SR is still 1, whatever comes after it.
        failed = dry_run(CELLS="U-RATE SR", REPEATS="1")
        self.assertEqual(failed.returncode, 1)
        self.assertNotIn("== dry-SR-r1", failed.stdout)

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
        self.assertEqual(p["convergenceRoster"], {"lt-client": {"1": 5}, "lt-good": {"4": 5, "5": 5}})
        self.assertEqual(p["scenarioOverride"], str(self.tmp / "scenario.json"))
        self.assertTrue(all(g["loopDelayP99Ms"] == 1.5 for g in record["groups"].values()))
        self.assertEqual(record["meta"]["wireForms"], {"lt-client": {"messagepack:fieldMerge,pathIndex": 7},
                                                       "lt-good": {"messagepack:fieldMerge,pathIndex": 7}})
        self.assertEqual(len(record["meta"]["impairSha256"]), 64)
        self.assertNotIn("failure", record["meta"])

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

    def sweep(self, run_id, **env):
        self.addCleanup(lambda: [shutil.rmtree(p, True) for p in (TOPIC / "data").glob(f"{run_id}*")])
        self.addCleanup(lambda: [p.unlink() for p in (TOPIC / "results").glob(f"{run_id}*.json")])
        full = {**self.env, "BUILD": "0", "GAMESERVER_BIN": str(self.tmp / "server.py"), "SERVER_CPUS": "", "CLIENT_CPUS": "",
                "ROOMS": "10", "CELLS": "M-COMBO", "REPEATS": "1", "RUN_ID": run_id, **env}
        return subprocess.run(["bash", str(TOPIC / "run.sh")], env=full, capture_output=True, text=True, timeout=120)

    def test_run_sh_stops_naming_the_failed_step(self):
        rid = f"test-stop-{os.getpid()}"
        done = self.sweep(rid, FAKE_FAIL="setup")
        self.assertEqual(done.returncode, 1)
        self.assertIn(f"STOPPED at {rid}-M-COMBO-r1: step setup failed", done.stderr)
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        self.assertTrue(record["cells"][-1]["status"].startswith("stopped: step setup failed"))
        self.assertEqual((record["build"], record["gameserverBin"]), (False, str(self.tmp / "server.py")))
        self.assertEqual(len(record["impairSha256"]), 64)

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
        self.assertEqual(record["cells"][-1]["status"], "ingested")
        run = json.loads((TOPIC / "data" / f"{rid}-M-COMBO-r1" / "run.json").read_text())
        self.assertEqual(run["meta"]["build"], False)
        self.assertIsNotNone(record["endedAt"])

    def test_run_sh_ends_a_passing_sweep_before_sr_with_exit_3(self):
        (self.tmp / "ingest.py").write_text("import sys\nsys.exit(0)\n")
        (self.tmp / "go.py").write_text("import sys\nsys.exit(0)\n")
        rid = f"test-sr-stop-{os.getpid()}"
        done = self.sweep(rid, CELLS="M-COMBO SR", ANALYSIS_PY=str(self.tmp / "ingest.py"), STOPCHECK_PY=str(self.tmp / "go.py"))
        self.assertEqual(done.returncode, 3, done.stdout + done.stderr)
        self.assertIn(f"STOPPED at {rid}-SR-r1: SR needs SR_PAUSE", done.stderr)
        record = json.loads((TOPIC / "data" / rid / "run.json").read_text())
        self.assertEqual([c["status"] for c in record["cells"]][0], "ingested")

    def test_run_sh_stops_when_ingest_fails(self):
        rid = f"test-ingest-{os.getpid()}"
        done = self.sweep(rid)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(f"STOPPED at {rid}-M-COMBO-r1: step ingest", done.stderr)


if __name__ == "__main__":
    unittest.main()
