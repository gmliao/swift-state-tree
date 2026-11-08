#!/usr/bin/env python3
"""Tests for run.sh's plan (its dry run), collect.py and regenerate.py --sweep, with no build and no
server: a synthetic sweep in run.sh's raw layout, made from the published reports under data/rerun/,
and one mutant of it per gate.

Usage: python3 test_topic.py
"""
import copy, gzip, json, os, pathlib, re, shutil, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import collect, regenerate  # noqa: E402
MATRIX = [("preflight", 500, True)] + [(f"suite-{s}-{n}", n, True) for s in (1, 2, 3) for n in (100, 300, 500)] + [
    ("overhead-profiled", 500, True), ("overhead-unprofiled", 500, False)]


def dry_run(**env):
    full = dict(os.environ, DRY_RUN="1", RUN_ID="dry", **env)
    for key in ("RUNS", "ROOMS", "PRE_S", "STEADY_S", "POST_S", "SERVER_CPUS", "CLIENT_CPUS", "PATH_INDEX", "FIELD_MERGE",
                "TRANSPORT_ENCODING", "WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS"):
        if key not in env:
            full.pop(key, None)
    return subprocess.run(["bash", str(TOPIC / "run.sh")], env=full, capture_output=True, text=True)


def runs(out):
    """(name, rooms, profiled, line) of every load invocation, in order."""
    found = []
    for line in out.splitlines():
        if "run-scalability-test.sh" not in line or not line.startswith("+ "):
            continue
        rooms = int(re.search(r"--room-counts (\d+)", line).group(1))
        name = re.search(r"--output-dir \S*/raw/dry/(\S+?)[ )]", line).group(1)
        found.append((name, rooms, "--profile" in line, line))
    return found


class Plan(unittest.TestCase):
    def test_full_matrix_in_order(self):
        done = dry_run()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)], MATRIX)
        for name, *_ in MATRIX:
            self.assertIn(f"+ status {name} ran", done.stdout)

    def test_every_run_waits_for_time_wait_first(self):
        lines = dry_run().stdout.splitlines()
        loads = [i for i, l in enumerate(lines) if "run-scalability-test.sh" in l]
        self.assertEqual(len(loads), len(MATRIX))
        for i in loads:
            before = [l for l in lines[:i] if l.startswith("+ wait until TIME_WAIT")]
            self.assertTrue(before, lines[i])
            # The wait, then the stale server log's removal, then the run: nothing else between them.
            self.assertTrue(lines[i - 2].startswith("+ wait until TIME_WAIT <= 200"), lines[i - 2])
            self.assertEqual(lines[i - 1], "+ rm -f /tmp/ws-loadtest-gameserver.log")
            self.assertTrue(lines[i + 2].startswith("+ check the summary names "), lines[i + 2])
        self.assertEqual(sum("stop the sweep if preflight failed" in l for l in lines), 1)
        self.assertEqual(sum(l.startswith("+ wait until TIME_WAIT") for l in lines), len(MATRIX))

    def test_one_build_before_the_first_run_and_every_run_uses_it(self):
        lines = dry_run().stdout.splitlines()
        builds = [i for i, l in enumerate(lines) if "swift build" in l]
        self.assertEqual(len(builds), 1)
        first_load = next(i for i, l in enumerate(lines) if "run-scalability-test.sh" in l)
        self.assertLess(builds[0], first_load)
        self.assertIn("-c release --product GameServer", lines[builds[0]])
        self.assertTrue(any(l.startswith("+ export GAMESERVER_BIN=") and "GAMESERVER_SOURCE_SHA=" in l for l in lines))

    def test_pinning_shims_and_their_check(self):
        out = dry_run().stdout
        self.assertIn("exec taskset -c 0-7 <stdbuf>", out)
        self.assertIn("exec taskset -c 8-11 <node>", out)
        self.assertIn("+ check the shims", out)
        self.assertTrue(all("PATH=" in line and "/shim:$PATH" in line for *_, line in runs(out)))
        custom = dry_run(SERVER_CPUS="0-3", CLIENT_CPUS="4,5").stdout
        self.assertIn("taskset -c 0-3 <stdbuf>", custom)
        self.assertIn("taskset -c 4,5 <node>", custom)

    def test_unpinned_has_no_shims(self):
        out = dry_run(SERVER_CPUS="", CLIENT_CPUS="").stdout
        self.assertNotIn("taskset", out)
        self.assertNotIn("check the shims", out)
        self.assertTrue(all("PATH=" not in line for *_, line in runs(out)))

    def test_outputs_stay_under_the_topics_ignored_raw(self):
        out = dry_run().stdout
        for *_, line in runs(out):
            self.assertRegex(line, r"--output-dir \.\./\.\./\.\./deep-research/multiroom-load-2026-11/raw/dry/")
            self.assertIn(f"> {TOPIC}/raw/dry/", line)
        path = "deep-research/multiroom-load-2026-11/raw/dry/run.json"
        ignored = subprocess.run(["git", "check-ignore", "-q", "--no-index", path], cwd=TOPIC.parent.parent)
        self.assertEqual(ignored.returncode, 0, f"{path} isn't ignored")

    def test_smoke_subset_rooms_and_phases(self):
        done = dry_run(RUNS="suite-1-100 overhead-unprofiled", ROOMS="10", PRE_S="2", STEADY_S="5", POST_S="2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)],
                         [("suite-1-100", 10, True), ("overhead-unprofiled", 10, False)])
        self.assertIn("preflight 2s, steady 5s, postflight 2s", done.stdout)
        self.assertTrue(all("--scenario ../../../deep-research/multiroom-load-2026-11/raw/dry/scenario.json" in line
                            for *_, line in runs(done.stdout)))
        default = dry_run(RUNS="preflight").stdout
        self.assertIn("--scenario scenarios/hero-defense/default.json", runs(default)[0][3])

    def test_bad_options_are_refused(self):
        for env in ({"RUNS": "nope"}, {"ROOMS": "x"}, {"ROOMS": "0"}, {"STEADY_S": "5s"}, {"RUN_ID": "a/b"},
                    {"PATH_INDEX": "off"}, {"FIELD_MERGE": "0"}):
            with self.subTest(env):
                done = subprocess.run(["bash", str(TOPIC / "run.sh")], env={**os.environ, "DRY_RUN": "1", "RUN_ID": "dry", **env},
                                      capture_output=True, text=True)
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)

    def test_an_existing_sweep_is_refused(self):
        run_id = f"test-existing-{os.getpid()}"
        out = TOPIC / "raw" / run_id
        out.mkdir(parents=True)
        try:
            (out / "run.json").write_text(json.dumps({"runId": run_id}))
            done = subprocess.run(["bash", str(TOPIC / "run.sh")], env=dict(os.environ, DRY_RUN="1", RUN_ID=run_id),
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)
            self.assertIn("already ran", done.stderr)
        finally:
            (out / "run.json").unlink()
            out.rmdir()


FAKE_SCALABILITY = r'''#!/usr/bin/env bash
# A stand-in for run-scalability-test.sh: one "run" per call, as FAKE_PLAN says for this run.
set -eu
while [ $# -gt 0 ]; do
  case "$1" in --room-counts) rooms=$2; shift 2 ;; --output-dir) out=$2; shift 2 ;; --scenario) shift 2 ;; *) shift ;; esac
done
name=$(basename "$out")
echo "$name" >> "$FAKE_CALLS"
mode=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "ok"))' "$FAKE_PLAN" "$name")
[ "$mode" = no-log ] || echo "server log of $name" > "$SERVER_LOG"
[ "$mode" = no-summary ] && exit 1
suite="$out/scalability-x"; mkdir -p "$suite/run-1"
report="$suite/run-1/ws-loadtest-1.json"
[ "$mode" = no-report ] || echo '{}' > "$report"
counts=$rooms; [ "$mode" = wrong-rooms ] && counts=$((rooms + 1))
echo "{\"config\": {\"roomCounts\": [$counts]}, \"runs\": [{\"rooms\": $counts, \"reportJson\": \"$report\"}]}" > "$suite/summary.json"
[ "$mode" = fail ] && exit 1
exit 0
'''


@unittest.skipUnless(sys.platform.startswith("linux"), "run.sh's real path runs on Linux")
class Driver(unittest.TestCase):
    """run.sh itself, not dry: a fake scalability script, fake `swift` and `ss`, unpinned."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "swift").write_text(f'#!/bin/sh\n[ "$1" = --version ] && printf "%s\\n" "{regenerate.PINNED_SWIFT}" "Target: x"\nexit 0\n')
        (bin_dir / "ss").write_text("#!/bin/sh\necho 'State Recv-Q Send-Q'\n")
        for f in bin_dir.iterdir():
            f.chmod(0o755)
        self.fake = self.tmp / "fake-scalability.sh"
        self.fake.write_text(FAKE_SCALABILITY)
        self.run_id = f"test-driver-{os.getpid()}-{id(self)}"
        self.out = TOPIC / "raw" / self.run_id
        self.addCleanup(shutil.rmtree, self.out, True)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", SERVER_CPUS="", CLIENT_CPUS="", RUN_ID=self.run_id,
                        SCALABILITY_SCRIPT=str(self.fake), SERVER_LOG=str(self.tmp / "server.log"),
                        FAKE_PLAN=str(self.tmp / "plan.json"), FAKE_CALLS=str(self.tmp / "calls"))
        for key in ("DRY_RUN", "ROOMS", "PRE_S", "STEADY_S", "POST_S", "OVERWRITE", "PATH_INDEX", "FIELD_MERGE", "TRANSPORT_ENCODING",
                    "WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS"):
            self.env.pop(key, None)

    def sweep(self, runs, plan=None):
        (self.tmp / "plan.json").write_text(json.dumps(plan or {}))
        # A leaked affinity watcher (it polls for 120 s) would hold the pipes open past the timeout.
        done = subprocess.run(["bash", str(TOPIC / "run.sh")], env=dict(self.env, RUNS=runs), capture_output=True, text=True, timeout=60)
        calls_file = self.tmp / "calls"
        calls = calls_file.read_text().split() if calls_file.exists() else []
        record = json.loads((self.out / "run.json").read_text())
        return done, calls, {c["tag"]: c["status"] for c in record["cells"]}

    def header(self, name):
        return (self.out / f"{name}.run-header.txt").read_text()

    def test_runs_pass_and_each_keeps_its_own_server_log(self):
        done, calls, status = self.sweep("preflight suite-1-100 overhead-unprofiled")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual(record["wire"], {"PATH_INDEX": None, "FIELD_MERGE": None, "TRANSPORT_ENCODING": None})
        self.assertEqual(record["sendBacklogEnv"], {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None})
        self.assertEqual(calls, ["preflight", "suite-1-100", "overhead-unprofiled"])
        self.assertEqual(set(status.values()), {"passed"})
        for name in calls:
            self.assertEqual((self.out / name / "gameserver.log").read_text(), f"server log of {name}\n")
            self.assertIn(f"server log: {name}/gameserver.log", self.header(name))

    def test_a_missing_server_log_is_recorded_not_the_previous_one(self):
        (self.tmp / "server.log").write_text("stale log of an earlier run\n")
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-300": "no-log"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.out / "suite-1-100" / "gameserver.log").read_text(), "server log of suite-1-100\n")
        self.assertFalse((self.out / "suite-1-300" / "gameserver.log").exists())
        self.assertIn("server log: none", self.header("suite-1-300"))

    def test_a_summary_of_another_room_count_stops_the_sweep(self):
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-100": "wrong-rooms"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["suite-1-100"])
        self.assertEqual(status, {"suite-1-100": "failed-no-summary"})
        self.assertIn("room counts are [101], not [100]", self.header("suite-1-100"))

    def test_a_summary_without_its_report_stops_the_sweep(self):
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-100": "no-report"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(status, {"suite-1-100": "failed-no-summary"})
        self.assertIn("has no report file", self.header("suite-1-100"))

    def test_no_summary_stops_the_sweep(self):
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-100": "no-summary"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(status, {"suite-1-100": "failed-no-summary"})

    def test_a_failed_preflight_stops_the_sweep(self):
        done, calls, status = self.sweep("preflight suite-1-100", {"preflight": "fail"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["preflight"])
        self.assertEqual(status, {"preflight": "failed-run"})
        self.assertIn("the preflight failed", done.stderr)

    def test_the_declared_wire_form_and_backlog_settings_are_recorded(self):
        self.env.update(PATH_INDEX="false", FIELD_MERGE="false", WS_SEND_BACKLOG_MAX_BYTES="1048576")
        done, calls, status = self.sweep("suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual(record["wire"], {"PATH_INDEX": "false", "FIELD_MERGE": "false", "TRANSPORT_ENCODING": None})
        self.assertEqual(record["sendBacklogEnv"]["WS_SEND_BACKLOG_MAX_BYTES"], "1048576")
        self.assertIn("WS_SEND_BACKLOG_* env: [1048576] [unset]", self.header("suite-1-100"))
        self.assertIn("wire env: PATH_INDEX=[false] FIELD_MERGE=[false] TRANSPORT_ENCODING=[unset]", self.header("suite-1-100"))

    def test_a_failed_suite_run_is_recorded_and_the_sweep_goes_on(self):
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-100": "fail"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["suite-1-100", "suite-1-300"])
        self.assertEqual(status, {"suite-1-100": "failed-run", "suite-1-300": "passed"})
        self.assertIsNotNone(json.loads((self.out / "run.json").read_text())["endedAt"])


SWIFT = regenerate.PINNED_SWIFT
NODE = "v20.20.2"
SHA = "a" * 40


def published(name):
    """The published report of a matrix run (data/rerun/ names the suites rerun-suite-*)."""
    return regenerate.load_gz(TOPIC / "data" / "rerun" / ("rerun-" + name if name.startswith("suite-") else name) / "report.json.gz")


def write_sweep(raw, run_id="sweep", features="fieldMerge,pathIndex", wire=None):
    """A finished, clean, pinned sweep of the whole matrix in run.sh's layout, at the server's
    default wire form unless `wire` declares another."""
    out = raw / run_id
    out.mkdir(parents=True)
    cells = []
    for name, (rooms, profiled) in regenerate.MATRIX.items():
        report = published(name)
        report["meta"]["runConfig"]["nodeVersion"] = NODE
        # A HEAD client records the joins' wire form per phase (the published 2026-11-06 reports predate it).
        for phase in report["phases"]:
            phase.setdefault("phaseTotals", {})["stateUpdateFeatures"] = {features: phase["connections"]}
        suite = out / name / "scalability-2026-11-08T00-00-00"
        (suite / "run-1").mkdir(parents=True)
        (suite / "run-1" / "ws-loadtest-1.json").write_text(json.dumps(report))
        (suite / "summary.json").write_text(json.dumps({"config": {"roomCounts": [rooms]}, "runs": [{"rooms": rooms, "success": True}]}))
        (suite / "run-1" / "toolchain.txt").write_text(
            f"{SWIFT}\nTarget: x86_64-unknown-linux-gnu\nnode {NODE}\n"
            f"GAMESERVER_BIN=/work/Examples/GameDemo/.build/release/GameServer\nGAMESERVER_SOURCE_SHA={SHA}\n")
        args = f"--room-counts {rooms} --scenario scenarios/hero-defense/default.json --output-dir ../../../x/{name}" + (" --profile" if profiled else "")
        (out / f"{name}.run-header.txt").write_text(
            f"sha={SHA}\nstart=2026-11-08T00:00:00Z\ncmd: PATH=/x/shim:$PATH bash scripts/run-scalability-test.sh {args}\n"
            f"shim stdbuf: exec taskset -c 0-7 /usr/bin/stdbuf \"$@\"\nshim node: exec taskset -c 8-11 /usr/bin/node \"$@\"\n"
            "WS_SEND_BACKLOG_* env: [unset] [unset]\n"
            f"{SWIFT}\n{NODE}\nexit=0 end=2026-11-08T00:01:00Z\nserver Cpus_allowed_list: 0-7\n")
        cells.append({"tag": name, "status": "passed", "finishedAt": "2026-11-08T00:01:00Z"})
    (out / "run.json").write_text(json.dumps({
        "runId": run_id, "repeat": 1, "order": "fixed", "capture": True, "pinCpus": "server:0-7 client:8-11",
        "allowUnverified": False, "onlyCells": None, "git": {"commit": SHA, "dirty": False}, "swiftVersion": SWIFT,
        "nodeVersion": NODE, "startedAt": "2026-11-08T00:00:00Z", "endedAt": "2026-11-08T01:00:00Z", "superseded": None,
        "cells": cells, "buildConfig": "release", "overrides": {}, "timeWait": {"max": 200, "timeoutS": 300},
        "wire": wire or {"PATH_INDEX": None, "FIELD_MERGE": None, "TRANSPORT_ENCODING": None},
        "sendBacklogEnv": {"WS_SEND_BACKLOG_MAX_BYTES": None, "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None}}))
    return out


def edit_json(path, change):
    data = json.loads(path.read_text())
    change(data)
    path.write_text(json.dumps(data))


def edit_text(path, old, new):
    text = path.read_text()
    assert old in text, (path, old)
    path.write_text(text.replace(old, new))


def report_path(out, name):
    return next((out / name).glob("scalability-*/run-1/ws-loadtest-*.json"))


def toolchain_path(out, name):
    return next((out / name).glob("scalability-*/run-1/toolchain.txt"))


def set_phase(name, field, value):
    def change(out):
        def apply(report):
            next(p for p in report["meta"]["runConfig"]["phases"] if p["name"] == "steady")[field] = value
        edit_json(report_path(out, name), apply)
    return change


def remove_run(name):
    def change(out):
        shutil.rmtree(out / name)
        (out / f"{name}.run-header.txt").unlink()
        edit_json(out / "run.json", lambda r: r.update(cells=[c for c in r["cells"] if c["tag"] != name]))
    return change


def set_features(out, name, counts):
    def apply(report):
        for phase in report["phases"]:
            phase["phaseTotals"]["stateUpdateFeatures"] = counts
    edit_json(report_path(out, name), apply)


def set_status(name, status):
    def change(out):
        edit_json(out / "run.json", lambda r: r["cells"].append({"tag": name, "status": status, "finishedAt": "x"}))
    return change


# One mutant per gate: (what, change to a valid raw sweep, words the refusal must contain).
MUTANTS = [
    ("debug build recorded", lambda o: edit_json(o / "run.json", lambda r: r.update(buildConfig="debug")), "not a release build"),
    ("debug GameServer binary", lambda o: edit_text(toolchain_path(o, "suite-2-100"), "/release/", "/debug/"), "suite-2-100: GameServer"),
    ("dirty tree", lambda o: edit_json(o / "run.json", lambda r: r["git"].update(dirty=True)), "not from a clean tree"),
    ("dirty unknown", lambda o: edit_json(o / "run.json", lambda r: r["git"].update(dirty=None)), "not from a clean tree"),
    ("no commit recorded", lambda o: edit_json(o / "run.json", lambda r: r["git"].update(commit=None)), "no commit recorded"),
    ("smoke: only some runs", lambda o: edit_json(o / "run.json", lambda r: r.update(onlyCells=["suite-1-100"])), "only runs"),
    ("smoke: overrides", lambda o: edit_json(o / "run.json", lambda r: r.update(overrides={"rooms": 10})), "overrides"),
    ("smoke: short steady phase unrecorded", set_phase("suite-3-500", "durationSeconds", 5), "suite-3-500: phases"),
    ("smoke: other room count unrecorded", set_phase("preflight", "rooms", 10), "preflight: phases"),
    ("missing run", remove_run("suite-2-300"), "missing runs: suite-2-300"),
    ("run without a report", lambda o: report_path(o, "overhead-profiled").unlink(), "missing runs: overhead-profiled"),
    ("sweep stopped at a run", set_status("suite-1-500", "failed-pinning"), "suite-1-500: status 'failed-pinning'"),
    ("sweep didn't finish", lambda o: edit_json(o / "run.json", lambda r: r.update(endedAt=None)), "didn't finish"),
    ("unpinned sweep", lambda o: edit_json(o / "run.json", lambda r: r.update(pinCpus="server:none client:none")), "pinning"),
    ("unpinned run (no shims)", lambda o: edit_text(o / "suite-1-300.run-header.txt", "taskset -c 8-11", "true"), "suite-1-300: unpinned"),
    ("server off its CPUs", lambda o: edit_text(o / "suite-2-500.run-header.txt", "list: 0-7", "list: 0-11"), "suite-2-500: the server ran on CPUs"),
    ("server CPUs not seen", lambda o: edit_text(o / "preflight.run-header.txt", "list: 0-7", "list: <not seen>"), "preflight: the server ran on CPUs"),
    ("Swift other than pinned", lambda o: edit_json(o / "run.json", lambda r: r.update(swiftVersion="Swift version 6.3.2 (swift-6.3.2-RELEASE)")), "the pinned toolchain"),
    ("Swift mismatch in one run", lambda o: edit_text(toolchain_path(o, "suite-3-100"), "6.2.4", "6.2.3"), "suite-3-100: Swift"),
    ("GameServer from another commit", lambda o: edit_text(toolchain_path(o, "suite-1-100"), "SHA=" + SHA, "SHA=" + "b" * 40), "suite-1-100: GameServer from"),
    ("profiler on in the unprofiled run", lambda o: edit_text(o / "overhead-unprofiled.run-header.txt", "default.json --output-dir ../../../x/overhead-unprofiled",
                                                               "default.json --output-dir ../../../x/overhead-unprofiled --profile"), "overhead-unprofiled: profiled True"),
    ("Node mismatch", lambda o: edit_json(report_path(o, "suite-2-100"), lambda r: r["meta"]["runConfig"].update(nodeVersion="v24.22.2")), "Node"),
    ("run outside the matrix", lambda o: (o / "extra").mkdir(), "runs not in the matrix: extra"),
    ("send backlog set for the sweep", lambda o: edit_json(o / "run.json", lambda r: r["sendBacklogEnv"].update(WS_SEND_BACKLOG_MAX_BYTES="1048576")),
     "send-backlog settings"),
    ("send backlog set in one run", lambda o: edit_text(o / "suite-1-100.run-header.txt", "env: [unset] [unset]", "env: [unset] [5000]"),
     "suite-1-100: send-backlog settings"),
    ("send backlog not recorded", lambda o: edit_json(o / "run.json", lambda r: r.pop("sendBacklogEnv")), "send-backlog settings weren't recorded"),
    ("send backlog not in a header", lambda o: edit_text(o / "preflight.run-header.txt", "WS_SEND_BACKLOG_* env: [unset] [unset]\n", ""),
     "preflight: send-backlog settings None"),
    ("wire form not recorded", lambda o: edit_json(o / "run.json", lambda r: r.pop("wire")), "wire form (PATH_INDEX, FIELD_MERGE) wasn't recorded"),
    ("joins in the old form at the defaults", lambda o: set_features(o, "suite-2-500", {"none": 1500}),
     "suite-2-500: messagepack, pathIndex off, fieldMerge off, intended messagepack, pathIndex on, fieldMerge on"),
    ("joins in two forms", lambda o: set_features(o, "suite-3-300", {"fieldMerge,pathIndex": 1000, "pathIndex": 500}),
     "suite-3-300: mixed wire forms in one run"),
    ("features not recorded", lambda o: edit_json(report_path(o, "overhead-profiled"), lambda r: [p["phaseTotals"].pop("stateUpdateFeatures") for p in r["phases"]]),
     "overhead-profiled: wire form missing: pathIndex not recorded"),
    ("like-for-like declared, defaults sent", lambda o: edit_json(o / "run.json", lambda r: r.update(wire={"PATH_INDEX": "false", "FIELD_MERGE": "false"})),
     "intended messagepack, pathIndex off, fieldMerge off"),
]


class Sweep(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.raw, self.results = self.tmp / "raw", self.tmp / "results"

    def regenerate(self, run_id="sweep"):
        collect.collect(self.raw, self.results)
        return subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--sweep", str(self.results / run_id)],
                              capture_output=True, text=True, encoding="utf-8")

    def test_a_valid_sweep_gives_the_published_tables(self):
        write_sweep(self.raw)
        done = self.regenerate()
        self.assertEqual(done.returncode, 0, done.stderr)
        readme = (TOPIC / "README.md").read_text(encoding="utf-8")
        # Same reports, so the same counters table; the steady table differs only in host CPU (n/a here).
        counters = readme.split("### Server counters, steady phase, each run")[1].split("###")[0].strip()
        self.assertIn(counters, done.stdout)
        self.assertIn("Profiler overhead, 500 rooms", done.stdout)
        self.assertIn("| 1 | 100 | 500 | 100 | 0.73 / 1.83 / 1.96 | 100 / 100 / 101 | 82.4 / 84.0 | n/a / n/a |", done.stdout)
        self.assertTrue((self.results / "sweep" / "suite-1-100" / "report.json.gz").exists())

    def test_every_mutant_is_refused_by_its_gate(self):
        for what, change, words in MUTANTS:
            with self.subTest(what):
                shutil.rmtree(self.tmp / "raw", ignore_errors=True)
                shutil.rmtree(self.tmp / "results", ignore_errors=True)
                change(write_sweep(self.raw))
                done = self.regenerate()
                self.assertNotEqual(done.returncode, 0, f"{what}: accepted")
                self.assertIn("results not usable", done.stderr)
                self.assertIn(words, done.stderr)

    def test_the_wire_form_is_named_and_a_like_for_like_rerun_is_accepted(self):
        write_sweep(self.raw)
        done = self.regenerate()
        self.assertIn("wire form messagepack, pathIndex on, fieldMerge on", done.stdout)
        self.assertIn("aren't comparable with this sweep's like for like", done.stdout)
        shutil.rmtree(self.raw)
        write_sweep(self.raw, features="none", wire={"PATH_INDEX": "false", "FIELD_MERGE": "false"})
        done = self.regenerate()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("wire form messagepack, pathIndex off, fieldMerge off", done.stdout)
        self.assertNotIn("comparable", done.stdout)

    def test_a_failed_run_is_a_result_not_a_refusal(self):
        out = write_sweep(self.raw)
        set_status("suite-3-500", "failed-run")(out)
        edit_text(out / "suite-3-500.run-header.txt", "exit=0", "exit=1")
        edit_json(report_path(out, "suite-3-500"), lambda r: next(p for p in r["phases"] if p["name"] == "steady").update(passed=False))
        done = self.regenerate()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertRegex(done.stdout, r"\| 3 \| 500 \|.*\| FAIL \|")

    def test_collect_skips_superseded_and_keeps_data_untouched(self):
        write_sweep(self.raw, "old")
        edit_json(self.raw / "old" / "run.json", lambda r: r.update(superseded={"at": "x", "reason": "redone"}))
        write_sweep(self.raw, "new")
        written = collect.collect(self.raw, self.results)
        self.assertEqual([p.name for p in written], ["new"])
        self.assertEqual(sorted(p.name for p in self.results.iterdir()), ["new"])
        # Collecting twice gives the same bytes (gzip without a timestamp).
        first = (self.results / "new" / "suite-1-100" / "report.json.gz").read_bytes()
        collect.collect(self.raw, self.results)
        self.assertEqual(first, (self.results / "new" / "suite-1-100" / "report.json.gz").read_bytes())
        check = subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--check"], capture_output=True, text=True,
                               env=dict(os.environ, PYTHONUTF8="1"))
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_a_features_key_turns_back_into_the_list(self):
        self.assertEqual(collect.features_from_key("none"), [])
        self.assertEqual(collect.features_from_key("fieldMerge,pathIndex"), ["fieldMerge", "pathIndex"])
        self.assertEqual(collect.features_from_key("pathIndex"), ["pathIndex"])

    def test_the_gates_matrix_is_run_shs(self):
        plan = [(n, r, p) for n, r, p, _ in runs(dry_run().stdout)]
        self.assertEqual(plan, [(n, r, p) for n, (r, p) in regenerate.MATRIX.items()])


if __name__ == "__main__":
    unittest.main()
