#!/usr/bin/env python3
"""Tests for run.sh's plan (its dry run), collect.py and regenerate.py --sweep, with no build and no
server: a synthetic sweep in run.sh's raw layout, made from the published reports under data/rerun/,
and one mutant of it per gate.

Usage: python3 test_topic.py
"""
import copy, gzip, json, os, pathlib, re, shutil, subprocess, sys, tempfile, unittest
from unittest import mock

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import clientload, collect, profiler_overhead, regenerate  # noqa: E402
sys.path.insert(0, str(TOPIC.parent))
import portable  # noqa: E402
MATRIX = [("preflight", 500, True), ("overhead-profiled", 500, True), ("overhead-unprofiled", 500, False)] + [
    (f"suite-{s}-{n}", n, True) for s in (1, 2, 3) for n in (100, 300, 500)]


def dry_run(**env):
    full = dict(os.environ, DRY_RUN="1", RUN_ID="dry", **env)
    for key in ("RUNS", "ROOMS", "PRE_S", "STEADY_S", "POST_S", "SERVER_CPUS", "CLIENT_CPUS", "PATH_INDEX", "FIELD_MERGE",
                "TRANSPORT_ENCODING", "WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS", "MOVE_TO_PER_S", "CONTROL",
                "TOP_ROOMS", "SUITE_ROOMS", "WORKLOAD", "STEADY_WARMUP_S"):
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
        # No shim on the PATH (HERO_DEFENSE_STATS_PATH= is the run's stats file, not a PATH).
        self.assertTrue(all(not re.search(r"(?<![A-Z_])PATH=", line) for *_, line in runs(out)))

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
                         [("overhead-unprofiled", 10, False), ("suite-1-100", 10, True)])
        self.assertIn("lengths (s) preflight 2, steady 5, postflight 2; steady measured after a 30 s warm-up", done.stdout)
        self.assertTrue(all("--scenario ../../../deep-research/multiroom-load-2026-11/raw/dry/scenario.json" in line
                            for *_, line in runs(done.stdout)))
        default = dry_run(RUNS="preflight").stdout
        # Every sweep runs a copy with steady's hold; the run's own stats file is on its load line.
        self.assertIn("--scenario ../../../deep-research/multiroom-load-2026-11/raw/dry/scenario.json", runs(default)[0][3])
        self.assertIn("HERO_DEFENSE_STATS_PATH=", runs(default)[0][3])
        self.assertIn("lengths (s) preflight default, steady default, postflight default; steady measured after a 30 s warm-up", default)

    def test_arm_zero_is_the_command_before_the_arms(self):
        # #430: arm 0 passes no flag, so its plan is the plan without MOVE_TO_PER_S, line for line.
        unset, zero = dry_run(), dry_run(MOVE_TO_PER_S="0")
        self.assertEqual(zero.returncode, 0, zero.stderr)
        self.assertEqual(unset.stdout, zero.stdout)
        self.assertIn("+ arm: MoveTo 0/s per player; control: 0", zero.stdout)
        self.assertTrue(all("--move-to-rate" not in line for *_, line in runs(zero.stdout)))

    def test_an_arm_passes_its_rate_to_every_run(self):
        done = dry_run(MOVE_TO_PER_S="5")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)], MATRIX)
        self.assertTrue(all(" --move-to-rate 5" in line for *_, line in runs(done.stdout)))
        self.assertIn("+ arm: MoveTo 5/s per player; control: 0", done.stdout)
        # The scenario is the same for every arm: the overlay is a client flag.
        self.assertIn("lengths (s) preflight default, steady default, postflight default", done.stdout)

    def test_the_control_is_one_run_at_arm_zero(self):
        done = dry_run(CONTROL="1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)], [("control-300", 300, True)])
        self.assertEqual(dict((n, (r, p)) for n, r, p, _ in runs(done.stdout)), regenerate.CONTROL_MATRIX)
        self.assertTrue(all("--move-to-rate" not in line for *_, line in runs(done.stdout)))
        self.assertIn("+ arm: MoveTo 0/s per player; control: 1", done.stdout)

    def test_every_profiled_run_keeps_its_server_profile(self):
        lines = dry_run().stdout.splitlines()
        checks = [l for l in lines if l.startswith("+ check the server profile is in ")]
        self.assertEqual([re.search(r"raw/dry/(\S+) ", l).group(1) for l in checks], [n for n, _, p in MATRIX if p])

    def test_the_overhead_pair_runs_after_the_preflight_and_is_checked_once(self):
        lines = dry_run().stdout.splitlines()
        loads = [n for n, *_ in runs("\n".join(lines))]
        self.assertEqual(loads[:3], ["preflight", "overhead-profiled", "overhead-unprofiled"])
        checks = [i for i, l in enumerate(lines) if l.startswith("+ check the profiler's overhead")]
        self.assertEqual(len(checks), 1)
        self.assertIn("overhead-unprofiled", next(l for l in reversed(lines[:checks[0]]) if "run-scalability-test.sh" in l))

    def test_the_sync_path_switches_are_unset_before_any_run(self):
        lines = dry_run().stdout.splitlines()
        unset = next(i for i, l in enumerate(lines) if l.startswith("+ unset USE_SNAPSHOT_FOR_SYNC IN_TURN_SYNC USE_SYNC_TABLES ROW_ADDRESSING SYNC_STRATEGY"))
        self.assertLess(unset, next(i for i, l in enumerate(lines) if "run-scalability-test.sh" in l))

    def test_every_run_checks_the_clients_load(self):
        lines = dry_run().stdout.splitlines()
        checks = [l for l in lines if l.startswith("+ check the client's load in every phase")]
        self.assertEqual(len(checks), len(MATRIX))
        self.assertTrue(all("client CPUs 8-11" in l and "failed-client-load" in l for l in checks))

    def test_the_room_counts_default_to_the_matrix_before_them(self):
        unset, explicit = dry_run(), dry_run(TOP_ROOMS="500", SUITE_ROOMS="100 300 500")
        self.assertEqual(unset.stdout, explicit.stdout)
        self.assertIn("rooms: top 500, suites 100 300 500", unset.stdout)

    def test_a_lower_top_and_fewer_suite_rooms(self):
        done = dry_run(TOP_ROOMS="300", SUITE_ROOMS="100 300", MOVE_TO_PER_S="5")
        self.assertEqual(done.returncode, 0, done.stderr)
        want = [("preflight", 300, True), ("overhead-profiled", 300, True), ("overhead-unprofiled", 300, False)] + [
            (f"suite-{s}-{n}", n, True) for s in (1, 2, 3) for n in (100, 300)]
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)], want)
        self.assertEqual(dict((n, (r, p)) for n, r, p, _ in runs(done.stdout)), regenerate.matrix_for(300, (100, 300)))
        self.assertIn("rooms: top 300, suites 100 300", done.stdout)

    def test_the_refreeze_workload_runs_the_games_ramp_without_a_hold(self):
        done = dry_run(WORKLOAD="refreeze", MOVE_TO_PER_S="2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([(n, r, p) for n, r, p, _ in runs(done.stdout)], MATRIX)
        self.assertIn("workload: refreeze", done.stdout)
        self.assertIn("steady with ws-loadtest's default warm-up (no hold)", done.stdout)
        self.assertIn("HERO_DEFENSE_SPAWN_RAMP_TICKS=unset (expected from the server: 3000)", done.stdout)
        plateau = dry_run().stdout
        self.assertIn("workload: plateau", plateau)
        self.assertIn("HERO_DEFENSE_SPAWN_RAMP_TICKS=0 (expected from the server: 0)", plateau)

    def test_bad_options_are_refused(self):
        for env in ({"RUNS": "nope"}, {"ROOMS": "x"}, {"ROOMS": "0"}, {"STEADY_S": "5s"}, {"RUN_ID": "a/b"},
                    {"PATH_INDEX": "off"}, {"FIELD_MERGE": "0"}, {"MOVE_TO_PER_S": "2/s"}, {"MOVE_TO_PER_S": ""},
                    {"CONTROL": "2"}, {"CONTROL": "1", "RUNS": "preflight"}, {"CONTROL": "1", "MOVE_TO_PER_S": "2"},
                    {"TOP_ROOMS": "0"}, {"TOP_ROOMS": "x"}, {"TOP_ROOMS": ""}, {"SUITE_ROOMS": "300 100"},
                    {"SUITE_ROOMS": "100 100"}, {"SUITE_ROOMS": "100 600"}, {"SUITE_ROOMS": ""}, {"SUITE_ROOMS": "1e2"},
                    {"WORKLOAD": "ramped"}, {"WORKLOAD": "refreeze", "STEADY_WARMUP_S": "30"}):
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
all="$*"
while [ $# -gt 0 ]; do
  case "$1" in --room-counts) rooms=$2; shift 2 ;; --output-dir) out=$2; shift 2 ;; --scenario) shift 2 ;; *) shift ;; esac
done
name=$(basename "$out")
echo "$name" >> "$FAKE_CALLS"
echo "$name ${HERO_DEFENSE_STATS_PATH:-unset}" >> "$FAKE_CALLS.stats"
echo "$name $all" >> "$FAKE_CALLS.args"
echo "$name ${IN_TURN_SYNC-unset} ${USE_SNAPSHOT_FOR_SYNC-unset} ${USE_SYNC_TABLES-unset} ${ROW_ADDRESSING-unset} ${SYNC_STRATEGY-unset} ${OUTBOUND_WRITER_MAX_BYTES-unset} ${JOIN_FLIP_BUDGET-unset}" >> "$FAKE_CALLS.syncenv"
mode=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "ok"))' "$FAKE_PLAN" "$name")
ramp=${HERO_DEFENSE_SPAWN_RAMP_TICKS:-3000}; [ "$mode" = ramp3000 ] && ramp=3000; [ "$mode" = ramp0 ] && ramp=0
[ "$mode" = no-log ] || printf 'server log of %s\nGameServer effective spawnRampTicks=%s (HERO_DEFENSE_SPAWN_RAMP_TICKS, default 3000)\n' "$name" "$ramp" > "$SERVER_LOG"
[ "$mode" = no-summary ] && exit 1
suite="$out/scalability-x"; mkdir -p "$suite/run-1"
report="$suite/run-1/ws-loadtest-1.json"
# The client's own load per phase (clientload.py): 2 workers, 11 % of a core with the orchestrator's 1 %, on
# the 4 CPUs the client saw (unpinned); client-busy: a worker's event loop at 0.9 in steady.
elu=0.2; [ "$mode" = client-busy ] && elu=0.9
p99=1.98; [ "$mode" = slow-rtt ] && p99=5.83
phase() { printf '{"name": "%s", "rtt": {"p99": %s}, "measurement": {"clientCpu": {"workers": 2, "perWorkerPct": {"min": 5, "mean": 5, "max": 5}, "orchestratorPct": 1, "totalPct": 11, "cores": 4}, "clientElu": {"workers": 2, "perWorker": {"min": 0.1, "mean": 0.15, "max": %s}}}}' "$1" "$p99" "$2"; }
case " $all " in *" --profile "*) [ "$mode" = no-profile ] || echo '{"ts": 1, "counters": {}}' > "$suite/run-1/transport-profile.jsonl" ;; esac
[ "$mode" = no-report ] || echo "{\"meta\": {\"runConfig\": {\"workers\": 2}}, \"phases\": [$(phase preflight 0.2), $(phase steady $elu), $(phase postflight 0.2)]}" > "$report"
counts=$rooms; [ "$mode" = wrong-rooms ] && counts=$((rooms + 1))
echo "{\"config\": {\"roomCounts\": [$counts]}, \"runs\": [{\"rooms\": $counts, \"reportJson\": \"$report\"}]}" > "$suite/summary.json"
[ "$mode" = fail ] && exit 1
exit 0
'''


class Refreeze(unittest.TestCase):
    """The README's Results: the MoveTo arms first (the refreeze sweep is archived), the 2026-11-06
    set as the captioned record."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.raw, self.results = self.tmp / "raw", self.tmp / "results"

    def test_before_the_sweep_the_record_follows_a_placeholder(self):
        text = regenerate.results_markdown(self.results)
        self.assertTrue(text.startswith("### MoveTo arms (#430)\n\n_Not run yet"))
        self.assertIn("### Pre-refreeze record (2026-11-06, server `ee8a407a`: messagepack, pathIndex off, fieldMerge off)", text)
        # The record's tables are the published ones, one level down.
        self.assertIn(regenerate.demote(regenerate.build()), text)
        self.assertNotIn("\n### Steady phase", text)

    def test_a_fixture_sweep_comes_first_and_the_dry_run_leaves_the_readme(self):
        write_arm_sweep(self.raw, "refreeze", 0)
        collect.collect(self.raw, self.results)
        readme = (TOPIC / "README.md").read_bytes()
        done = subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--results", str(self.results), "--markdown"],
                              capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((TOPIC / "README.md").read_bytes(), readme)
        sweep, record = done.stdout.split("### Pre-refreeze record", 1)
        self.assertTrue(sweep.startswith("### MoveTo arms (#430)\n\nWorkload: Hero Defense's spawn ramp skipped"), sweep[:200])
        self.assertIn("\n\n#### MoveTo 0/s per player\n\nProvenance, from the results' meta: commit `", sweep)
        self.assertIn(f", clean tree; Swift 6.2.4; Node {NODE}; build release.\n\nSweep `refreeze`, wire form", sweep)
        self.assertIn("wire form messagepack, pathIndex on, fieldMerge on", sweep)
        self.assertIn("\n##### Steady phase, each run", sweep)
        self.assertIn("#### MoveTo 2/s per player\n\n_Not run yet._", sweep)
        self.assertNotIn("Sensitivity", sweep)  # one arm: nothing to compare
        self.assertIn("\n#### Steady phase, each run", record)

    def test_the_sweep_section_keeps_every_gate(self):
        write_arm_sweep(self.raw, "refreeze", 0)
        edit_json(self.raw / "refreeze" / "run.json", lambda r: r.update(overrides={"rooms": 10}))
        collect.collect(self.raw, self.results)
        with self.assertRaisesRegex(SystemExit, "a smoke sweep"):
            regenerate.results_markdown(self.results)

    def test_a_second_sweep_of_an_arm_is_refused(self):
        write_arm_sweep(self.raw, "a", 0)
        write_arm_sweep(self.raw, "b", 0)
        collect.collect(self.raw, self.results)
        with self.assertRaisesRegex(SystemExit, "more than one sweep for an arm: 0: a, b"):
            regenerate.results_markdown(self.results)

    def test_a_sweep_without_an_arm_is_refused_and_the_archive_isnt_read(self):
        write_sweep(self.raw, "old")
        collect.collect(self.raw, self.results)
        with self.assertRaisesRegex(SystemExit, "old records no MoveTo arm"):
            regenerate.results_markdown(self.results)
        # Under results/archive/ it's no input, and --sweep still prints it.
        (self.results / "archive").mkdir()
        (self.results / "old").rename(self.results / "archive" / "old")
        self.assertTrue(regenerate.results_markdown(self.results).startswith("### MoveTo arms (#430)\n\n_Not run yet"))
        self.assertIn("Sweep `old`", regenerate.build_sweep(self.results / "archive" / "old"))

    def test_the_archived_refreeze_still_prints(self):
        archived = TOPIC / "results" / "archive" / "20261109T140702Z-022d8fdb"
        # The results section reads results/*/sweep.json only: the archive is no input, whatever else is there.
        dirs = regenerate.sweep_dirs(TOPIC / "results")
        self.assertNotIn(archived, dirs)
        self.assertTrue(all(d.parent == TOPIC / "results" and d.name != "archive" for d in dirs), dirs)
        tables = regenerate.build_sweep(archived)
        self.assertIn("Sweep `20261109T140702Z-022d8fdb`", tables)
        self.assertIn("### Steady phase, each run", tables)
        # Its pair breaks the bound applied since the arms: flagged with the episode, not refused.
        self.assertIn("**Outside the profiler-overhead bound** applied since the MoveTo arms: profiled steady RTT p99 5.83 ms "
                      "against 1.98 ms, over max(+1 ms, +25 %). This set predates the gate: archived, not refused. Observed: in the "
                      "profiled run, 2 of its 56 measured 1 s windows had an RTT p99 over 2.98 ms (16 s: p50 0.89, p99 6.96 ms; "
                      "17 s: p50 5.86, p99 7.90 ms, counted from the steady origin). The host's 1-minute load average was 3.4 "
                      "before them and 4.33 during them.", tables)
        # The 2026-11-06 pair is within it: no flag in the record.
        self.assertNotIn("Outside the profiler-overhead bound", regenerate.build())

    def test_collect_can_take_one_sweep(self):
        write_sweep(self.raw, "smoke")
        write_sweep(self.raw, "refreeze")
        written = collect.collect(self.raw, self.results, "refreeze")
        self.assertEqual([p.name for p in written], ["refreeze"])
        self.assertEqual(sorted(p.name for p in self.results.iterdir()), ["refreeze"])

    def test_a_record_that_isnt_both_knobs_off_is_refused(self):
        sha = self.tmp / "SHA.txt"
        sha.write_text(KNOBS_COMMIT + "\n")  # a commit with both knobs, and the reports record no form
        with mock.patch.object(regenerate, "RECORD_COMMIT", sha):
            with self.assertRaisesRegex(SystemExit, "pre-refreeze record not usable"):
                regenerate.results_markdown(self.results)


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
                    "WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS", "MOVE_TO_PER_S", "CONTROL", "TOP_ROOMS",
                    "SUITE_ROOMS", "WORKLOAD", "STEADY_WARMUP_S", "HERO_DEFENSE_SPAWN_RAMP_TICKS",
                    "USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "USE_SYNC_TABLES", "ROW_ADDRESSING", "SYNC_STRATEGY",
                    "OUTBOUND_WRITER_MAX_BYTES", "JOIN_FLIP_BUDGET"):
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
        # run.sh walks its matrix in order, whatever order RUNS names them: the pair right after the preflight.
        self.assertEqual(calls, ["preflight", "overhead-unprofiled", "suite-1-100"])
        # Steady holds 30 s at 5 players before its 60 s measured window (#425), and each run's
        # server writes its own land stats.
        scenario = json.loads((self.out / "scenario.json").read_text())
        steady = scenario["phases"]["steady"]
        self.assertEqual((steady["warmupSeconds"], steady["durationSeconds"], steady["playersPerRoom"]), (30, 90, 5))
        self.assertEqual(record["steadyWarmupS"], 30)
        given = dict(l.split(" ", 1) for l in (self.tmp / "calls.stats").read_text().splitlines())
        self.assertEqual(given, {n: str(self.out / n / "land-stats.jsonl") for n in calls})
        self.assertEqual(set(status.values()), {"passed"})
        for name in calls:
            self.assertTrue((self.out / name / "gameserver.log").read_text().startswith(f"server log of {name}\n"))
            self.assertIn(f"server log: {name}/gameserver.log", self.header(name))
            self.assertIn("server spawnRampTicks: 0", self.header(name))
        # The ramp asked for, and per run the one each server reported.
        self.assertEqual(record["spawnRampTicks"], 0)
        self.assertEqual(record["spawnRampTicksEffective"], {name: 0 for name in calls})

    def test_an_arm_is_recorded_and_its_rate_reaches_every_run(self):
        self.env["MOVE_TO_PER_S"] = "2"
        done, calls, status = self.sweep("preflight suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual((record["moveToPerS"], record["control"]), (2, False))
        args = (self.tmp / "calls.args").read_text().splitlines()
        self.assertEqual(len(args), 2)
        self.assertTrue(all(" --move-to-rate 2" in line for line in args), args)
        self.assertIn("client load: within the bounds", self.header("suite-1-100"))

    def test_arm_zero_passes_no_flag_and_records_zero(self):
        done, calls, status = self.sweep("suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual((record["moveToPerS"], record["control"]), (0, False))
        self.assertNotIn("--move-to-rate", (self.tmp / "calls.args").read_text())

    def test_a_busy_load_client_stops_the_sweep(self):
        done, calls, status = self.sweep("preflight suite-1-100 suite-1-300", {"suite-1-100": "client-busy"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["preflight", "suite-1-100"])
        self.assertEqual(status, {"preflight": "passed", "suite-1-100": "failed-client-load"})
        self.assertIn("steady: worst worker ELU 0.9, the limit is 0.5", done.stderr)
        self.assertIn("client load: steady: worst worker ELU 0.9", self.header("suite-1-100"))

    def test_a_profiled_run_without_its_server_profile_stops_the_sweep(self):
        done, calls, status = self.sweep("preflight suite-1-100 suite-1-300", {"suite-1-100": "no-profile"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(status, {"preflight": "passed", "suite-1-100": "failed-no-profile"})
        self.assertIn("server profile: none", self.header("suite-1-100"))
        self.assertRegex(self.header("preflight"), r"server profile: preflight/scalability-x/run-1/transport-profile.jsonl")

    def test_the_unprofiled_run_needs_no_profile(self):
        done, calls, status = self.sweep("overhead-unprofiled")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("server profile", self.header("overhead-unprofiled"))
        # Without its profiled half in the invocation, the pair's gate says it didn't run.
        self.assertIn("profiler overhead: not checked (overhead-profiled didn't run in this invocation)", self.header("overhead-unprofiled"))

    def test_a_profiler_that_moved_the_tail_stops_the_sweep_before_the_suites(self):
        done, calls, status = self.sweep("preflight overhead-profiled overhead-unprofiled suite-1-100", {"overhead-profiled": "slow-rtt"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["preflight", "overhead-profiled", "overhead-unprofiled"])
        self.assertEqual(status["overhead-unprofiled"], "failed-profiler-overhead")
        self.assertIn("steady RTT p99 5.83 ms profiled against 1.98 ms unprofiled, +3.85 ms, over the bound of +1.00 ms",
                      self.header("overhead-unprofiled"))

    def test_a_profiler_within_the_bound_lets_the_suites_run(self):
        done, calls, status = self.sweep("overhead-profiled overhead-unprofiled suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(calls, ["overhead-profiled", "overhead-unprofiled", "suite-1-100"])
        self.assertIn("profiler overhead: steady RTT p99 1.98 ms profiled, 1.98 ms unprofiled: within the bound",
                      self.header("overhead-unprofiled"))

    def test_a_refreeze_sweep_runs_the_games_ramp_and_writes_no_hold(self):
        self.env["WORKLOAD"] = "refreeze"
        done, calls, status = self.sweep("preflight suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual((record["workload"], record["spawnRampTicks"], record["steadyWarmupS"]), ("refreeze", 3000, None))
        self.assertEqual(record["spawnRampTicksEffective"], {"preflight": 3000, "suite-1-100": 3000})
        steady = json.loads((self.out / "scenario.json").read_text())["phases"]["steady"]
        self.assertNotIn("warmupSeconds", steady)
        self.assertEqual(steady["durationSeconds"], 60)
        self.assertIn("spawn ramp env: HERO_DEFENSE_SPAWN_RAMP_TICKS=[unset]", self.header("suite-1-100"))

    def test_a_server_without_the_ramp_stops_a_refreeze_sweep(self):
        self.env["WORKLOAD"] = "refreeze"
        done, calls, status = self.sweep("preflight suite-1-100", {"preflight": "ramp0"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(status, {"preflight": "failed-spawn-ramp"})
        self.assertIn("the server ran with spawnRampTicks '0', not 3000", done.stderr)

    def test_the_sync_path_switches_are_recorded_and_unset_for_the_server(self):
        # #468: a shell with them set records them (syncPathEnv) and the server never sees them.
        self.env.update(IN_TURN_SYNC="false", USE_SYNC_TABLES="true", SYNC_STRATEGY="full-snapshot", OUTBOUND_WRITER_MAX_BYTES="1024")
        done, calls, status = self.sweep("suite-1-100")
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual(record["syncPathEnv"], {"USE_SNAPSHOT_FOR_SYNC": None, "IN_TURN_SYNC": "false", "USE_SYNC_TABLES": "true",
                                                 "ROW_ADDRESSING": None, "SYNC_STRATEGY": "full-snapshot",
                                                 "OUTBOUND_WRITER_MAX_BYTES": "1024", "JOIN_FLIP_BUDGET": None})
        self.assertEqual((self.tmp / "calls.syncenv").read_text().split(), ["suite-1-100"] + ["unset"] * 7)
        self.assertIn("sync-path env: unset for the server; the shell had USE_SNAPSHOT_FOR_SYNC=[unset] IN_TURN_SYNC=[false] "
                      "USE_SYNC_TABLES=[true] ROW_ADDRESSING=[unset] SYNC_STRATEGY=[full-snapshot] OUTBOUND_WRITER_MAX_BYTES=[1024] "
                      "JOIN_FLIP_BUDGET=[unset]", self.header("suite-1-100"))

    def test_the_control_is_recorded(self):
        self.env["CONTROL"] = "1"
        (self.tmp / "plan.json").write_text("{}")
        done = subprocess.run(["bash", str(TOPIC / "run.sh")], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        record = json.loads((self.out / "run.json").read_text())
        self.assertEqual((record["moveToPerS"], record["control"]), (0, True))
        self.assertEqual((self.tmp / "calls").read_text().split(), ["control-300"])

    def test_a_missing_server_log_is_recorded_not_the_previous_one(self):
        (self.tmp / "server.log").write_text("stale log of an earlier run\n")
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-300": "no-log"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.out / "suite-1-100" / "gameserver.log").read_text().startswith("server log of suite-1-100\n"))
        self.assertFalse((self.out / "suite-1-300" / "gameserver.log").exists())
        self.assertIn("server log: none", self.header("suite-1-300"))

    def test_a_server_that_ran_another_spawn_ramp_stops_the_sweep(self):
        done, calls, status = self.sweep("suite-1-100 suite-1-300", {"suite-1-100": "ramp3000"})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, ["suite-1-100"])
        self.assertEqual(status, {"suite-1-100": "failed-spawn-ramp"})
        self.assertIn("server spawnRampTicks: 3000", self.header("suite-1-100"))
        self.assertIn("ran with spawnRampTicks '3000', not 0", done.stderr)

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
# A commit that has both knobs (#308's merge): needs the repository's history.
KNOBS_COMMIT = "49fde351"
NODE = "v20.20.2"
SHA = "c657c37b303799811764a4d7799a0b91c7399341"  # a real commit before row addressing came in: the form resolves without it


def published(name):
    """The published report of a matrix run (data/rerun/ names the suites rerun-suite-*; the control
    is suite-1's run at 300 rooms)."""
    name = "suite-1-300" if name == "control-300" else name
    return regenerate.load_gz(TOPIC / "data" / "rerun" / ("rerun-" + name if name.startswith("suite-") else name) / "report.json.gz")


def report_for(name, rooms):
    """A published report for a matrix run at `rooms`: its own, or suite-1's at that room count when the
    matrix runs it elsewhere (a lower TOP_ROOMS)."""
    published_rooms = (regenerate.MATRIX.get(name) or regenerate.CONTROL_MATRIX.get(name) or (None,))[0]
    return published(name if published_rooms == rooms else f"suite-1-{rooms}")


def write_sweep(raw, run_id="sweep", features="messagepack:fieldMerge,pathIndex", wire=None, matrix=None):
    """A finished, clean, pinned sweep of the whole matrix (or `matrix`) in run.sh's layout, at the
    server's default wire form unless `wire` declares another."""
    out = raw / run_id
    out.mkdir(parents=True)
    cells = []
    for name, (rooms, profiled) in (matrix or regenerate.MATRIX).items():
        report = report_for(name, rooms)
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
            f"GAMESERVER_BIN=/workspace/checkout/Examples/GameDemo/.build/release/GameServer\nGAMESERVER_SOURCE_SHA={SHA}\n")
        args = f"--room-counts {rooms} --scenario scenarios/hero-defense/default.json --output-dir ../../../x/{name}" + (" --profile" if profiled else "")
        (out / f"{name}.run-header.txt").write_text(
            f"sha={SHA}\nstart=2026-11-08T00:00:00Z\ncmd: PATH=/x/shim:$PATH bash scripts/run-scalability-test.sh {args}\n"
            f"shim stdbuf: exec taskset -c 0-7 /usr/bin/stdbuf \"$@\"\nshim node: exec taskset -c 8-11 /usr/bin/node \"$@\"\n"
            "WS_SEND_BACKLOG_* env: [unset] [unset]\n"
            f"{SWIFT}\n{NODE}\nexit=0 end=2026-11-08T00:01:00Z\nserver Cpus_allowed_list: 0-7\n")
        cells.append({"tag": name, "status": "passed", "finishedAt": "2026-11-08T00:01:00Z"})
    (out / "run.json").write_text(json.dumps({
        "runId": run_id, "repeat": 1, "order": "fixed", "capture": True, "pinCpus": "server:0-7 client:8-11",
        "allowUnverified": False, "onlyCells": None, "git": {"commit": SHA, "dirty": False, "root": "/workspace/checkout"}, "swiftVersion": SWIFT,
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
    ("no commit recorded", lambda o: edit_json(o / "run.json", lambda r: r["git"].update(commit=None)), "sweep.json: no commit in its meta"),
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
    ("joins in the old form at the defaults", lambda o: set_features(o, "suite-2-500", {"messagepack:none": 1500}),
     "suite-2-500: messagepack, pathIndex off, fieldMerge off, intended messagepack, pathIndex on, fieldMerge on"),
    ("joins in two forms", lambda o: set_features(o, "suite-3-300", {"messagepack:fieldMerge,pathIndex": 1000, "messagepack:pathIndex": 500}),
     "suite-3-300: wire form missing: joins were given different wire forms"),
    ("features not recorded", lambda o: edit_json(report_path(o, "overhead-profiled"), lambda r: [p["phaseTotals"].pop("stateUpdateFeatures") for p in r["phases"]]),
     "overhead-profiled: wire form missing: encoding None not recorded"),
    ("joins in another encoding", lambda o: set_features(o, "suite-1-300", {"json:fieldMerge,pathIndex": 1500}),
     "suite-1-300: json, pathIndex on, fieldMerge on, intended messagepack"),
    ("another encoding declared", lambda o: edit_json(o / "run.json", lambda r: r["wire"].update(TRANSPORT_ENCODING="json")),
     "intended json, pathIndex off, fieldMerge off"),
    ("encoding not named by the server", lambda o: set_features(o, "suite-2-100", {"unknown:fieldMerge,pathIndex": 1500}),
     "suite-2-100: wire form missing: encoding None not recorded"),
    ("like-for-like declared, defaults sent", lambda o: edit_json(o / "run.json", lambda r: r.update(wire={"PATH_INDEX": "false", "FIELD_MERGE": "false"})),
     "intended messagepack, pathIndex off, fieldMerge off"),
]


def write_hold_sweep(raw, monsters=lambda t: 30, hold=30, effective=0, without_stats=(), run_id="sweep", matrix=None):
    """write_sweep with steady's hold, as run.sh runs it since the spawn ramp is skipped (#425):
    each report's steady phase lasts 60 s more than ``hold`` with ``hold`` as its warm-up, each run
    has its server's land-stats.jsonl (``monsters(t)`` live per land, t in s from steady's origin;
    none for the runs in ``without_stats``), and run.json records the hold, the ramp asked for and
    each server's (``effective``)."""
    matrix = matrix or regenerate.MATRIX
    out = write_sweep(raw, run_id, matrix=matrix)
    for name in matrix:
        path = one_report(out / name)
        report = json.loads(path.read_text())
        for phase in report["meta"]["runConfig"]["phases"]:
            if phase["name"] == "steady":
                phase.update(durationSeconds=60 + hold, warmupMs=hold * 1000)
        steady = next(p for p in report["phases"] if p["name"] == "steady")
        steady["measurement"].update(warmupMs=hold * 1000, measuredMs=60_000)
        path.write_text(json.dumps(report))
        if name in without_stats:
            continue
        origin = steady["measurement"]["originAt"]
        rows = [{"fromTs": origin + t * 1000 - 1000, "ts": origin + t * 1000, "writeFailures": 0,
                 "lands": {f"l{i}": {"tick": t * 20, "monsters": monsters(t), "baseHealth": 0, "players": 5,
                                     "spawned": 7 * t, "killed": 5 * t, "reachedBase": 2 * t} for i in range(3)}}
                for t in range(0, 60 + hold + 5)]
        (out / name / "land-stats.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    edit_json(out / "run.json", lambda r: r.update(steadyWarmupS=hold, spawnRampTicks=0,
                                                   spawnRampTicksEffective={n: effective for n in matrix}))
    return out


def write_arm_sweep(raw, run_id, arm, control=False, elu=0.2, sent=None, achieved=0.99, top=None, rooms=None, workload="plateau"):
    """write_hold_sweep as run.sh runs an arm (#430): run.json records the arm (and the control),
    each report's client was configured with `sent` (default: the arm) MoveTo events per player per
    second and sent them, and every phase records the client's ELU (`elu`, the worst worker's)."""
    matrix = regenerate.CONTROL_MATRIX if control else (regenerate.matrix_for(top, rooms) if top else None)
    if workload == "refreeze":
        # The refreeze's rules: no hold (the published reports' default warm-up), the game's own ramp.
        out = write_sweep(raw, run_id, matrix=matrix)
        names = list(matrix or regenerate.MATRIX)
        edit_json(out / "run.json", lambda r: r.update(workload="refreeze", spawnRampTicks=3000, steadyWarmupS=None,
                                                       spawnRampTicksEffective={n: 3000 for n in names}))
    else:
        out = write_hold_sweep(raw, run_id=run_id, matrix=matrix)
    rate = arm if sent is None else sent
    for name in (matrix or regenerate.MATRIX):
        path = one_report(out / name)
        report = json.loads(path.read_text())
        report["meta"]["runConfig"]["events"] = [{"name": "MoveTo", "ratePerSecond": rate, "payloadGenerator": "moveTo"}] if rate else []
        for phase in report["phases"]:
            m = phase["measurement"]
            m["clientElu"] = {"workers": report["meta"]["runConfig"]["workers"], "perWorker": {"min": 0.1, "mean": 0.15, "max": elu}}
            if rate:
                target = rate * phase["connections"]
                m["events"] = {"MoveTo": {"ratePerPlayerPerSecond": rate, "targetPerSecond": target,
                                          "sentInWindow": int(target * achieved * 50), "achievedPerSecond": target * achieved,
                                          "perPlayerPerSecond": rate * achieved}}
        path.write_text(json.dumps(report))
    edit_json(out / "run.json", lambda r: r.update(moveToPerS=arm, control=control))
    if top:
        edit_json(out / "run.json", lambda r: r.update(topRooms=top, suiteRooms=list(rooms)))
    return out


def one_report(run_dir):
    return next(run_dir.glob("scalability-*/run-1/ws-loadtest-*.json"))


class Arms(unittest.TestCase):
    """The MoveTo arms (#430): one gated sweep per arm, a sensitivity table across them, the
    host-drift control reported, and the load client held to clientload.py's bounds."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.raw, self.results = self.tmp / "raw", self.tmp / "results"

    def section(self):
        collect.collect(self.raw, self.results)
        return regenerate.sweep_section(self.results)

    def test_three_arms_and_the_control(self):
        for arm in regenerate.ARMS:
            write_arm_sweep(self.raw, f"arm-{arm}", arm)
        write_arm_sweep(self.raw, "control", 0, control=True)
        text = self.section()
        for arm in regenerate.ARMS:
            self.assertIn(f"#### MoveTo {arm}/s per player\n\nProvenance", text)
        self.assertIn("#### Sensitivity to the players' input rate", text)
        self.assertIn("| rooms | steady phase | MoveTo 0/s | MoveTo 2/s | MoveTo 5/s |", text)
        self.assertIn("| 300 | MoveTo sent per player per s | 0 [0–0] | 1.98 [1.98–1.98] | 4.95 [4.95–4.95] |", text)
        self.assertIn("isn't in the client's report", text)
        # The control is suite-1-300's published report, inside arm 0's 300-room runs: within the band, untabled.
        self.assertIn("**Host-drift control** (`control`, suite-1 at 300 rooms at arm 0", text)
        self.assertIn(": within it. It isn't tabled.", text)
        self.assertNotIn("control-300 |", text)

    def test_a_control_outside_arm_zeros_band_is_flagged(self):
        write_arm_sweep(self.raw, "arm-0", 0)
        out = write_arm_sweep(self.raw, "control", 0, control=True)
        def hot(report):
            next(e for e in report["serverCpu"] if e["phase"] == "steady")["summary"]["meanPct"] *= 2
        edit_json(one_report(out / "control-300"), hot)
        self.assertIn("**outside it: the set is flagged for host drift**", self.section())

    def test_the_arms_section_refuses_what_it_cant_compare(self):
        cases = [
            ("a control without arm 0", lambda: (write_arm_sweep(self.raw, "arm-2", 2), write_arm_sweep(self.raw, "c", 0, control=True)),
             "a control sweep without the arm-0 sweep"),
            ("two controls", lambda: (write_arm_sweep(self.raw, "arm-0", 0), write_arm_sweep(self.raw, "c1", 0, control=True),
                                      write_arm_sweep(self.raw, "c2", 0, control=True)), "2 control sweeps"),
            ("two commits", lambda: (write_arm_sweep(self.raw, "arm-0", 0),
                                     edit_json(write_arm_sweep(self.raw, "arm-2", 2) / "run.json", lambda r: r["git"].update(commit="b" * 40))),
             "the sweeps are from 2 commits"),
            ("an arm off the list", lambda: write_arm_sweep(self.raw, "arm-3", 3), "MoveTo arm 3: the arms are 0, 2, 5"),
            ("reports configured for another rate", lambda: write_arm_sweep(self.raw, "arm-2", 2, sent=5),
             "the client was configured for MoveTo at 5 per player per second, the arm is 2"),
            ("a client that sent short of its rate", lambda: write_arm_sweep(self.raw, "arm-5", 5, achieved=0.7),
             "steady: MoveTo achieved"),
            ("a control without its arm recorded", lambda: (write_arm_sweep(self.raw, "arm-0", 0),
                                                            edit_json(write_arm_sweep(self.raw, "c", 0, control=True) / "run.json",
                                                                      lambda r: r.pop("moveToPerS"))),
             "a control sweep without its arm recorded"),
            ("a busy load client", lambda: write_arm_sweep(self.raw, "arm-5", 5, elu=0.9), "steady: worst worker ELU 0.9, the limit is 0.5"),
            ("a control at another arm", lambda: (write_arm_sweep(self.raw, "arm-0", 0),
                                                  edit_json(write_arm_sweep(self.raw, "c", 0, control=True) / "run.json",
                                                            lambda r: r.update(moveToPerS=2))), "a control at arm 2"),
        ]
        for what, make, words in cases:
            with self.subTest(what):
                shutil.rmtree(self.raw, True)
                shutil.rmtree(self.results, True)
                make()
                with self.assertRaises(SystemExit) as e:
                    self.section()
                self.assertIn(words, str(e.exception))

    def test_an_arm_whose_profiler_moved_the_tail_is_refused(self):
        out = write_arm_sweep(self.raw, "arm-0", 0)
        edit_json(one_report(out / "overhead-profiled"),
                  lambda r: next(p for p in r["phases"] if p["name"] == "steady")["rtt"].update(p99=5.83))
        with self.assertRaisesRegex(SystemExit, "profiler overhead: steady RTT p99 5.83 ms profiled"):
            self.section()

    def test_a_sweep_from_before_the_arms_still_prints_with_sweep(self):
        # collect.py writes moveToPerS: null for it; that's no arm, not arm None.
        write_hold_sweep(self.raw)
        collect.collect(self.raw, self.results)
        self.assertIsNone(json.loads((self.results / "sweep" / "sweep.json").read_text())["moveToPerS"])
        self.assertIn("Sweep `sweep`", regenerate.build_sweep(self.results / "sweep"))
        with self.assertRaisesRegex(SystemExit, "sweep records no MoveTo arm"):
            regenerate.sweep_section(self.results)

    def test_a_shortfall_is_measured_against_the_target(self):
        report = {"meta": {"runConfig": {"events": [{"name": "MoveTo", "ratePerSecond": 5}]}},
                  "phases": [{"name": "steady", "measurement": {"events": {"MoveTo": {"targetPerSecond": 12500, "achievedPerSecond": 11875}}}}]}
        self.assertEqual(regenerate.move_to_failures(report, 5), [])  # exactly 95 %
        report["phases"][0]["measurement"]["events"]["MoveTo"]["achievedPerSecond"] = 8750
        self.assertEqual(regenerate.move_to_failures(report, 5), ["steady: MoveTo achieved 8750.0/s of a 12500.0/s target (70%), under 95%"])
        zero = {"meta": {"runConfig": {"events": []}}, "phases": [{"name": "steady", "measurement": {"events": {"MoveTo": {"sentInWindow": 3}}}}]}
        self.assertEqual(regenerate.move_to_failures(zero, 0), ["steady: 3 MoveTo sent at arm 0"])

    def test_arms_at_a_lower_top_are_tabled_with_their_own_room_counts(self):
        # A host under 500 rooms' capacity: arm 0 at top 300 with 100 and 300, arm 5 at top 300 with 100 only.
        write_arm_sweep(self.raw, "arm-0", 0, top=300, rooms=(100, 300))
        write_arm_sweep(self.raw, "arm-5", 5, top=300, rooms=(100,))
        write_arm_sweep(self.raw, "control", 0, control=True)
        text = self.section()
        self.assertIn("Room counts: the preflight and the overhead pair at 300, the suites at 100, 300.", text)
        self.assertIn("Room counts: the preflight and the overhead pair at 300, the suites at 100.", text)
        self.assertIn("##### Profiler overhead, 300 rooms, back to back", text)
        self.assertIn("| 100 | MoveTo sent per player per s | 0 [0–0] | not run | 4.95 [4.95–4.95] |", text)
        self.assertIn("| 300 | MoveTo sent per player per s | 0 [0–0] | not run | not run |", text)
        # No 500-room row anywhere: the per-room-count and sensitivity tables start with the room count, the
        # per-run and counter tables have it second (after the suite). A 500 elsewhere is connections (100 x 5).
        self.assertIsNone(re.search(r"^\| 500 \|", text, re.M))
        self.assertIsNone(re.search(r"^\| [123] \| 500 \|", text, re.M))
        self.assertRegex(text, r"(?m)^\| 1 \| 100 \| 500 \|")  # what the old assertion tripped on: 100 rooms, 500 connections
        self.assertIn(": within it. It isn't tabled.", text)  # arm 0 ran 300 rooms

    def test_a_control_without_arm_zeros_300_rooms_is_not_compared(self):
        write_arm_sweep(self.raw, "arm-0", 0, top=100, rooms=(100,))
        write_arm_sweep(self.raw, "control", 0, control=True)
        self.assertIn("not compared, since arm 0 ran no 300-room suites", self.section())

    def test_recorded_room_counts_out_of_order_are_refused(self):
        out = write_arm_sweep(self.raw, "arm-0", 0, top=300, rooms=(100, 300))
        edit_json(out / "run.json", lambda r: r.update(suiteRooms=[300, 100]))
        with self.assertRaisesRegex(SystemExit, "suite room counts \\[300, 100\\] with top 300"):
            self.section()

    def test_a_refreeze_set_is_tabled_and_captioned(self):
        for arm in regenerate.ARMS:
            write_arm_sweep(self.raw, f"arm-{arm}", arm, workload="refreeze")
        write_arm_sweep(self.raw, "control", 0, control=True, workload="refreeze")
        text = self.section()
        # collect.py carries the workload into sweep.json: without it a refreeze sweep would read as no workload.
        self.assertEqual(json.loads((self.results / "arm-0" / "sweep.json").read_text())["workload"], "refreeze")
        self.assertTrue(text.startswith("### MoveTo arms (#430)\n\nWorkload: the refreeze sweep's rules"), text[:200])
        self.assertIn("#### Sensitivity to the players' input rate", text)
        self.assertIn(": within it. It isn't tabled.", text)

    def test_a_set_of_two_workloads_is_refused(self):
        write_arm_sweep(self.raw, "arm-0", 0)
        write_arm_sweep(self.raw, "arm-2", 2, workload="refreeze")
        with self.assertRaisesRegex(SystemExit, "the sweeps ran different workloads \\(arm-0: plateau; arm-2: refreeze\\)"):
            self.section()

    def test_a_refreeze_arm_whose_server_skipped_the_ramp_is_refused(self):
        out = write_arm_sweep(self.raw, "arm-0", 0, workload="refreeze")
        edit_json(out / "run.json", lambda r: r["spawnRampTicksEffective"].update({"suite-2-300": 0}))
        with self.assertRaisesRegex(SystemExit, "suite-2-300: the server reported spawn ramp 0, not 3000"):
            self.section()

    def test_a_refreeze_arm_with_a_hold_is_refused(self):
        out = write_arm_sweep(self.raw, "arm-0", 0, workload="refreeze")
        edit_json(out / "run.json", lambda r: r.update(steadyWarmupS=30))
        with self.assertRaisesRegex(SystemExit, "steady warm-up 30 s, the refreeze workload holds None"):
            self.section()

    def test_a_client_without_its_elu_is_refused(self):
        out = write_arm_sweep(self.raw, "arm-0", 0)
        edit_json(one_report(out / "suite-2-500"), lambda r: [p["measurement"].pop("clientElu") for p in r["phases"]])
        with self.assertRaisesRegex(SystemExit, "suite-2-500: preflight: client load missing \\(no clientElu"):
            self.section()


class ProfilerOverhead(unittest.TestCase):
    """profiler_overhead.py: the pair's bound, max(+1 ms, +25 %) of the unprofiled steady RTT p99."""

    @staticmethod
    def report(p99):
        return {"phases": [{"name": "steady", "rtt": {"p99": p99}}]}

    def test_the_bound(self):
        fail = profiler_overhead.failure
        # The refreeze sweep's pair (archived): refused.
        self.assertIn("+3.85 ms, over the bound of +1.00 ms", fail(self.report(5.834), self.report(1.98)))
        # +1 ms at a small tail, +25 % at a large one, both inclusive.
        self.assertIsNone(fail(self.report(2.98), self.report(1.98)))
        self.assertIsNotNone(fail(self.report(3.0), self.report(1.98)))
        self.assertIsNone(fail(self.report(12.5), self.report(10)))
        self.assertIsNotNone(fail(self.report(12.6), self.report(10)))
        # Faster when profiled is fine; a missing figure isn't.
        self.assertIsNone(fail(self.report(1.0), self.report(1.98)))
        self.assertIn("not measured", fail({"phases": []}, self.report(1.98)))

    def test_the_published_pairs(self):
        # The 2026-11-06 pair passes; the archived refreeze pair doesn't.
        self.assertIsNone(profiler_overhead.failure(published("overhead-profiled"), published("overhead-unprofiled")))
        archive = TOPIC / "results" / "archive" / "20261109T140702Z-022d8fdb"
        refreeze = {n: regenerate.load_gz(archive / n / "report.json.gz") for n in ("overhead-profiled", "overhead-unprofiled")}
        self.assertIn("profiler overhead: steady RTT p99 5.83 ms profiled against 1.98 ms unprofiled",
                      profiler_overhead.failure(refreeze["overhead-profiled"], refreeze["overhead-unprofiled"]))


class ClientLoad(unittest.TestCase):
    """clientload.py: the rule run.sh stops on and regenerate.py refuses by."""

    def report(self, total=58.8, orchestrator=0.2, elu=0.2, workers=12, covered=12, cores=12):
        phase = lambda name: {"name": name, "measurement": {
            "clientCpu": {"workers": covered, "perWorkerPct": {}, "orchestratorPct": orchestrator, "totalPct": total, "cores": cores},
            "clientElu": {"workers": covered, "perWorker": {"min": 0, "mean": 0, "max": elu}}}}
        return {"meta": {"runConfig": {"workers": workers}}, "phases": [phase(n) for n in clientload.PHASES]}

    def test_the_demand_is_the_workers_over_the_pinned_cpus(self):
        load = clientload.measure(self.report(), "8-11")
        self.assertEqual(load["phases"]["steady"], {"cpuDemandPct": 14.6, "cpus": 4, "eluMax": 0.2, "missing": None})
        self.assertEqual(clientload.failures(load), [])
        # Unpinned: over the CPUs the client saw.
        self.assertEqual(clientload.measure(self.report(), None)["phases"]["steady"]["cpuDemandPct"], 4.9)
        self.assertEqual(clientload.client_mask("server:0-7 client:8-11"), "8-11")
        self.assertIsNone(clientload.client_mask("server:none client:none"))

    def test_the_bounds(self):
        self.assertIn("steady: workers' CPU demand 70.0 % of 4 CPUs, the limit is under 70 %: the client may be the bottleneck",
                      clientload.failures(clientload.measure(self.report(total=280.2), "8-11")))
        self.assertIn("steady: workers' CPU demand 120.0 % of 4 CPUs: over 100 %, the measurement is broken",
                      clientload.failures(clientload.measure(self.report(total=480.2), "8-11")))
        self.assertIn("steady: worst worker ELU 0.51, the limit is 0.5", clientload.failures(clientload.measure(self.report(elu=0.51), "8-11")))
        self.assertEqual(clientload.failures(clientload.measure(self.report(elu=0.5, total=279.0), "8-11")), [])

    def test_every_worker_counts_and_missing_fails(self):
        short = clientload.failures(clientload.measure(self.report(covered=11), "8-11"))
        self.assertIn("steady: client load missing (clientCpu covers 11 of 12 workers; clientElu covers 11 of 12 workers)", short)
        published_report = published("suite-1-300")  # the 2026-11-06 client: no clientElu
        self.assertIn("steady: client load missing (no clientElu (a client before it was reported))",
                      clientload.failures(clientload.measure(published_report, "8-11")))
        self.assertEqual(clientload.failures(None), ["client load not measured"])

    def test_a_check_that_cant_read_its_inputs_exits_2(self):
        done = subprocess.run([sys.executable, str(TOPIC / "clientload.py"), "check", "/nonexistent/summary.json", "/", "8-11"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        self.assertIn("client load check failed: FileNotFoundError", done.stdout)

    def test_check_exits_by_the_rule(self):
        tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        for name, report, code in (("ok", self.report(), 0), ("busy", self.report(elu=0.9), 1)):
            (tmp / f"{name}.json").write_text(json.dumps(report))
            (tmp / f"{name}-summary.json").write_text(json.dumps({"runs": [{"reportJson": str(tmp / f"{name}.json")}]}))
            done = subprocess.run([sys.executable, str(TOPIC / "clientload.py"), "check", str(tmp / f"{name}-summary.json"), str(tmp), "8-11"],
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, code, done.stdout + done.stderr)
        self.assertIn("steady: worst worker ELU 0.9", done.stdout)


class SteadyHold(unittest.TestCase):
    """A sweep with steady's hold (#425): every report holds 30 s at 5 players before steady's 60 s
    measured window, the servers ran without the spawn ramp, and the monster load is stationary in
    every run's measured window (landstats.py, from the run's own land-stats.jsonl). Sweeps without
    the hold (the published ones) keep the old phases."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.raw, self.results = self.tmp / "raw", self.tmp / "results"

    def failures(self, **kw):
        write_hold_sweep(self.raw, **kw)
        collect.collect(self.raw, self.results)
        sweep = json.loads((self.results / "sweep" / "sweep.json").read_text())
        reports = {n: regenerate.load_gz(self.results / "sweep" / n / "report.json.gz") for n in regenerate.MATRIX}
        return sweep, regenerate.sweep_failures(sweep, reports)

    def test_a_stationary_hold_sweep_is_tabled(self):
        sweep, failures = self.failures()
        self.assertEqual(failures, [])
        stats = sweep["runs"]["suite-1-100"]["steadyLandStats"]
        # Six 10 s bins over the measured window, from the hold's end; the flows per land per s.
        self.assertEqual([b["s"] for b in stats["bins"]], [0, 10, 20, 30, 40, 50])
        self.assertEqual(stats["bins"][0]["rates"], {"spawned": 7.0, "killed": 5.0, "reachedBase": 2.0})
        self.assertEqual((sweep["steadyWarmupS"], sweep["spawnRampTicks"]), (30, 0))
        done = subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--sweep", str(self.results / "sweep")],
                              capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_growing_load_in_the_window_is_refused(self):
        # The count still grows through the measured window (t 30-90 s): not stationary.
        _, failures = self.failures(monsters=lambda t: 2 + t // 3)
        self.assertTrue(any("steady window's monster load isn't stationary" in f for f in failures), failures)

    def test_the_hold_the_ramp_and_the_stats_must_all_be_there(self):
        cases = {
            "a shorter hold": ({"hold": 20}, "steady warm-up 20 s, the plateau workload holds 30"),
            "a server on the game's ramp": ({"effective": 3000}, "the server reported spawn ramp 3000, not 0"),
            "a run without stats": ({"without_stats": ("suite-1-300",)}, "suite-1-300: no land stats for the steady window"),
        }
        for name, (kw, words) in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.raw, ignore_errors=True)
                shutil.rmtree(self.results, ignore_errors=True)
                _, failures = self.failures(**kw)
                self.assertTrue(any(words in f for f in failures), failures)

    def test_a_sweep_without_the_hold_keeps_the_published_phases(self):
        write_sweep(self.raw)
        collect.collect(self.raw, self.results)
        sweep = json.loads((self.results / "sweep" / "sweep.json").read_text())
        reports = {n: regenerate.load_gz(self.results / "sweep" / n / "report.json.gz") for n in regenerate.MATRIX}
        self.assertIsNone(sweep.get("steadyWarmupS"))
        self.assertEqual(regenerate.sweep_failures(sweep, reports), [])


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
        # The fixture's reports are data/rerun/'s, the pre-refreeze record, so its counters table is
        # that section's (not the refreeze sweep's, which results/ fills); the steady table differs
        # only in host CPU (n/a here).
        record = readme.split("### Pre-refreeze record")[1]
        counters = record.split("Server counters, steady phase, each run")[1].split("\n#")[0].strip()
        self.assertTrue(counters.startswith("| suite | rooms | sync cycles |"), counters[:80])
        self.assertIn(counters, done.stdout)
        self.assertIn("Profiler overhead, 500 rooms", done.stdout)
        self.assertIn("| 1 | 100 | 500 | 100 | 0.73 / 1.83 / 1.96 | 100 / 100 / 101 | 82.4 / 84.0 | n/a / n/a |", done.stdout)
        self.assertTrue((self.results / "sweep" / "suite-1-100" / "report.json.gz").exists())

    def test_a_sweep_without_the_dirty_flag_is_refused_at_collect_and_at_regenerate(self):
        edit_json(write_sweep(self.raw) / "run.json", lambda r: r["git"].update(dirty=None))
        with self.assertRaises(SystemExit) as cm:
            collect.collect(self.raw, self.results)
        self.assertIn("run.json: no git.dirty recorded (got None); run the sweep with this topic's run.sh", str(cm.exception))
        # A collected sweep.json without the flag (one collected before collect refused it).
        shutil.rmtree(self.raw)
        shutil.rmtree(self.results, ignore_errors=True)
        write_sweep(self.raw)
        collect.collect(self.raw, self.results)
        edit_json(self.results / "sweep" / "sweep.json", lambda s: s["git"].update(dirty=None))
        done = subprocess.run([sys.executable, str(TOPIC / "regenerate.py"), "--sweep", str(self.results / "sweep")],
                              capture_output=True, text=True, encoding="utf-8")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("not from a clean tree (git dirty: None): no git.dirty recorded; run the sweep with this topic's run.sh",
                      done.stderr)

    def test_every_tracked_sweep_records_a_clean_tree(self):
        # No tracked sweep is grandfathered, archived ones included: each records git.dirty false.
        sweeps = sorted((TOPIC / "results").glob("*/sweep.json")) + sorted((TOPIC / "results" / "archive").glob("*/sweep.json"))
        self.assertTrue(sweeps)
        for path in sweeps:
            with self.subTest(path.parent.name):
                self.assertIs((json.loads(path.read_text()).get("git") or {}).get("dirty"), False)

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
        write_sweep(self.raw, features="messagepack:none", wire={"PATH_INDEX": "false", "FIELD_MERGE": "false"})
        done = self.regenerate()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("wire form messagepack, pathIndex off, fieldMerge off", done.stdout)
        self.assertNotIn("comparable", done.stdout)

    def test_a_json_sweep_at_default_knobs_is_accepted(self):
        # With JSON-object updates the server echoes no features (TransportEncodingConfig), so the
        # declared form is json with both off even though PATH_INDEX and FIELD_MERGE are unset.
        write_sweep(self.raw, features="json:none", wire={"PATH_INDEX": None, "FIELD_MERGE": None, "TRANSPORT_ENCODING": "json"})
        done = self.regenerate()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("wire form json, pathIndex off, fieldMerge off", done.stdout)

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

    def test_collected_results_carry_no_absolute_path(self):
        # The host's run-time files name the GameServer it ran by its absolute path in that checkout.
        write_sweep(self.raw)
        collect.collect(self.raw, self.results)
        files = sorted(p for p in self.results.rglob("*") if p.is_file())
        self.assertTrue(files)
        for f in files:
            text = gzip.decompress(f.read_bytes()).decode() if f.suffix == ".gz" else f.read_text()
            self.assertEqual(portable.absolute_paths(text), [], f.relative_to(self.results))
        sweep = json.loads((self.results / "sweep" / "sweep.json").read_text())
        self.assertEqual(sweep["runs"]["suite-1-100"]["toolchain"]["gameserverBin"], "Examples/GameDemo/.build/release/GameServer")
        self.assertNotIn("root", sweep["git"])

    def test_a_record_without_its_checkout_root_needs_one_and_other_paths_stay(self):
        write_sweep(self.raw)
        edit_json(self.raw / "sweep" / "run.json", lambda r: r["git"].pop("root"))
        with self.assertRaises(SystemExit) as cm:
            collect.collect(self.raw, self.results)
        self.assertIn("--checkout-root", str(cm.exception))
        # A path outside the checkout stays visible, for the guard to catch.
        tc = next((self.raw / "sweep" / "suite-1-100").glob("scalability-*/run-1/toolchain.txt"))
        tc.write_text(tc.read_text() + "npm /usr/local/lib/node_modules/npm/scripts/postinstall.js\n")
        collect.collect(self.raw, self.results, checkout_root="/workspace/checkout")
        copied = (self.results / "sweep" / "suite-1-100" / "toolchain.txt").read_text()
        self.assertIn("GAMESERVER_BIN=Examples/GameDemo/.build/release/GameServer", copied)
        self.assertIn("npm /usr/local/lib/node_modules/npm/scripts/postinstall.js", copied)

    def test_no_features_is_both_off_but_no_map_is_a_missing_input(self):
        # A server with every feature off sends no field; the client's key is "<encoding>:none".
        encoding, features = regenerate.wireform.join_form({"messagepack:none": 3})
        form = regenerate.wireform.resolve(KNOBS_COMMIT, encoding, features=features)
        self.assertEqual((form.path_index, form.field_merge), (False, False))
        # A report without the map: an older client recorded nothing, a missing input at a commit
        # that has the knobs.
        report = {"phases": [{"name": "preflight", "phaseTotals": {"errorCount": 0}}]}
        self.assertIsNone(collect.join_features(report))
        with self.assertRaises(regenerate.wireform.MissingWireForm):
            regenerate.wireform.resolve(KNOBS_COMMIT, "messagepack", features=collect.join_features(report))

    def test_the_gates_matrix_is_run_shs(self):
        plan = [(n, r, p) for n, r, p, _ in runs(dry_run().stdout)]
        self.assertEqual(plan, [(n, r, p) for n, (r, p) in regenerate.MATRIX.items()])


class AfterRowDefault(unittest.TestCase):
    """ROW_ADDRESSING's default after its flip (gameserver_wire.ROW_DEFAULT_COMMIT set; a stand-in,
    6f7920c0, which this checkout contains and c657c37b, its parent, doesn't)."""

    def setUp(self):
        self.saved, regenerate.gameserver_wire.ROW_DEFAULT_COMMIT = regenerate.gameserver_wire.ROW_DEFAULT_COMMIT, "6f7920c0"

    def tearDown(self):
        regenerate.gameserver_wire.ROW_DEFAULT_COMMIT = self.saved

    def test_a_sweep_without_a_commit_is_refused_not_a_crash(self):
        failures = regenerate.sweep_failures({"wire": {}, "git": {"commit": None}}, {})
        self.assertIn("intended wire form missing: ROW_ADDRESSING unset and the server commit not recorded: "
                      "its default changed in 6f7920c0", failures)

    def test_the_commit_decides(self):
        self.assertFalse(regenerate.intended_form({}, "c657c37b").row_addressing)
        self.assertTrue(regenerate.intended_form({}, "6f7920c0").row_addressing)
        self.assertFalse(regenerate.intended_form({"ROW_ADDRESSING": "false"}, "6f7920c0").row_addressing)


if __name__ == "__main__":
    unittest.main()
