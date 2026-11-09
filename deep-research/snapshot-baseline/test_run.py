#!/usr/bin/env python3
"""Tests for run.sh, runmeta.py and collect.py, with no build: run.sh's dry run, and full runs
against a stand-in benchmark, swift, npm and node in a temporary copy of the topic.

Usage: python3 test_run.py
"""
import json, os, pathlib, shutil, stat, subprocess, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from serverenv import SERVER_ENV  # noqa: E402

TOPIC = pathlib.Path(__file__).resolve().parent
BENCH = ".build/release/EncodingBenchmark"


def commands(out):
    return [line[2:] for line in out.splitlines() if line.startswith("+ ")]


def measured(cmds):
    """The measured benchmark invocations (not the gate passes)."""
    return [c for c in cmds if BENCH in c and "--capture-views" not in c]


def strategy(cmd):
    words = cmd.split()
    return words[words.index("--sync-strategy") + 1]


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class Sandbox:
    """A copy of the topic at <tmp>/deep-research/snapshot-baseline, with stand-ins for the
    benchmark binary and for swift, npm and node on PATH. The benchmark writes a result file
    and prints "Results saved to:"; node's verify-views writes its report, and fails for the
    tag in FAIL_GATE."""

    def __init__(self, tmp):
        root = pathlib.Path(tmp)
        self.topic = root / "deep-research" / "snapshot-baseline"
        self.topic.mkdir(parents=True)
        for name in ("run.sh", "runmeta.py", "collect.py"):
            shutil.copy(TOPIC / name, self.topic / name)
        shutil.copy(TOPIC.parent / "serverenv.py", self.topic.parent / "serverenv.py")
        shutil.copy(TOPIC.parent / "gitstate.py", self.topic.parent / "gitstate.py")  # runmeta.py imports both
        gd = root / "Examples" / "GameDemo"
        executable(gd / BENCH, """#!/usr/bin/env bash
out="$(mktemp "${TMPDIR:-/tmp}/bench-XXXXXX")"
printf '{"metadata":{"commandLine":["%s"]},"results":[]}\\n' "$*" > "$out"
echo "Results saved to: $out"
""")
        executable(gd / "ws-loadtest" / "scripts" / "ensure-deps.sh", "#!/usr/bin/env bash\n")
        self.bin = root / "bin"
        executable(self.bin / "swift", "#!/usr/bin/env bash\n[ \"$1\" = --version ] && echo 'Swift version 6.2.4 (stand-in)'\nexit 0\n")
        executable(self.bin / "npm", "#!/usr/bin/env bash\nexit 0\n")
        executable(self.bin / "node", """#!/usr/bin/env bash
[ "$1" = --version ] && { echo v22.0.0; exit 0; }
while [ $# -gt 0 ]; do case "$1" in --capture) cap="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) shift ;; esac; done
case "$cap" in *".views-$FAIL_GATE") exit 1 ;; esac
echo '{"differences":0}' > "$out"
""")

    def run(self, **env):
        full = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "PIN_CPUS": "", "FAIL_GATE": "", "SMOKE": "1", **env}
        return subprocess.run(["bash", str(self.topic / "run.sh")], env=full, capture_output=True, text=True)

    def record(self, run_id):
        return json.loads((self.topic / "raw" / run_id / "run.json").read_text())


def dry_run(**env):
    return subprocess.run(["bash", str(TOPIC / "run.sh")], env={**os.environ, "DRY_RUN": "1", "SMOKE": "1", **env},
                          capture_output=True, text=True)


class DryRun(unittest.TestCase):
    def test_default_sweep(self):
        proc = dry_run(REPEAT="1", RUN_ID="sweep-a")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.splitlines()[0], "RUN_ID=sweep-a")
        cmds = commands(proc.stdout)
        self.assertIn("swift build -c release --product EncodingBenchmark", cmds)
        self.assertIn(f"write {TOPIC}/raw/sweep-a/run.json", cmds)
        self.assertIn("unset " + " ".join(SERVER_ENV), cmds)
        self.assertNotIn("USE_SNAPSHOT_FOR_SYNC=false", proc.stdout)
        runs = measured(cmds)
        self.assertEqual(len(runs), 12)
        for c in runs:
            self.assertTrue(c.startswith(f"taskset -c 0-7 {BENCH} "), c)
            self.assertIn("--parallel false", c)
            self.assertIn("--format messagepack-pathhash", c)
            self.assertIn(f"> {TOPIC}/raw/sweep-a/", c)
            self.assertRegex(c, r"mv <Results saved to> \S+/raw/sweep-a/[a-z0-9-]+\.json$")
        # Delta first, the full snapshot right after it, per axis.
        self.assertEqual([strategy(c) for c in runs], ["delta", "full-snapshot"] * 6)
        self.assertIn("--monster-cap 100", runs[9])
        gates = [c for c in cmds if "--capture-views" in c]
        self.assertEqual(len(gates), 12)
        self.assertEqual(len([c for c in cmds if f"--out {TOPIC}/raw/sweep-a/" in c and "verify-views" in c]), 12)
        self.assertNotIn("json-object", proc.stdout)

    def test_generated_run_id(self):
        proc = dry_run(REPEAT="1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=TOPIC).stdout.strip()
        self.assertRegex(proc.stdout, rf"RUN_ID=\d{{8}}T\d{{6}}Z-{sha}\n")

    def test_repeat_order_extra_without_gate(self):
        proc = dry_run(REPEAT="2", RUN_ID="sweep-b", ORDER="snapshot-first", VERIFY_VIEWS="0", EXTRA="1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cmds = commands(proc.stdout)
        runs = measured(cmds)
        self.assertEqual(len(runs), 16)
        for c in runs:
            self.assertIn(f"> {TOPIC}/raw/sweep-b/", c)
            self.assertTrue(c.startswith(f"taskset -c 0-7 {BENCH} "), c)
            self.assertIn("--parallel false", c)
        self.assertEqual([strategy(c) for c in runs[:12]], ["full-snapshot", "delta"] * 6)
        extra = runs[12:]
        self.assertIn("--format json-object --iterations 200 --ticks-per-sync 2 --parallel false --players-per-room-list 5 --room-counts 10,30,50 --sync-strategy delta", extra[0])
        self.assertIn("rq1-rooms-json-delta.log", extra[0])
        self.assertIn("--format json-object", extra[1])
        self.assertIn("--room-counts 100,300,500", extra[1])
        self.assertEqual([strategy(c) for c in extra[2:]], ["full-snapshot", "delta"])
        self.assertTrue(all("--format messagepack-pathhash" in c and "--room-counts 100,300,500" in c for c in extra[2:]))
        self.assertFalse(any("--capture-views" in c or "verify-views" in c for c in cmds))

    def test_extra_gates_only_the_json_rows(self):
        cmds = commands(dry_run(REPEAT="1", RUN_ID="s", EXTRA="1").stdout)
        gates = [c for c in cmds if "--capture-views" in c]
        self.assertEqual(len(gates), 13)
        self.assertIn("--format json-object", gates[-1])
        self.assertIn("--room-counts 10,30,50", gates[-1])
        self.assertFalse(any("100,300,500" in g for g in gates))

    def test_unpinned_and_bad_options(self):
        runs = measured(commands(dry_run(REPEAT="1", RUN_ID="s", PIN_CPUS="").stdout))
        self.assertTrue(runs and all(c.startswith(BENCH) for c in runs))
        bad = dry_run(REPEAT="1", ORDER="full-first")
        self.assertEqual(bad.returncode, 2)
        self.assertIn("ORDER must be", bad.stderr)
        missing = dry_run()
        self.assertEqual(missing.returncode, 2)
        self.assertIn("REPEAT is required", missing.stderr)
        self.assertEqual(dry_run(REPEAT="x").returncode, 2)
        self.assertEqual(dry_run(REPEAT="1", RUN_ID="../raw").returncode, 2)

    def test_a_failing_server_variable_list_stops_the_sweep(self):
        # Without ../serverenv.py, python3 fails: run.sh must stop before anything runs, not unset nothing.
        with tempfile.TemporaryDirectory() as tmp:
            topic = pathlib.Path(tmp) / "deep-research" / "snapshot-baseline"
            topic.mkdir(parents=True)
            (pathlib.Path(tmp) / "Examples" / "GameDemo").mkdir(parents=True)
            shutil.copy(TOPIC / "run.sh", topic / "run.sh")
            proc = subprocess.run(["bash", str(topic / "run.sh")], capture_output=True, text=True,
                                  env={**os.environ, "DRY_RUN": "1", "SMOKE": "1", "REPEAT": "1", "RUN_ID": "s"})
            self.assertEqual(proc.returncode, 1, proc.stdout)
            self.assertNotIn("EncodingBenchmark", proc.stdout)
            self.assertIn("serverenv.py", proc.stderr)

    def test_a_sweep_without_extra_is_refused_unless_a_smoke(self):
        for env in (dict(SMOKE="0"), dict(SMOKE="0", EXTRA="0"), dict(SMOKE="")):
            with self.subTest(env):
                proc = dry_run(REPEAT="2", RUN_ID="s", **env)
                self.assertEqual(proc.returncode, 2)
                self.assertIn("EXTRA=1 is required", proc.stderr)
        self.assertEqual(dry_run(REPEAT="2", RUN_ID="s", SMOKE="0", EXTRA="1").returncode, 0)
        self.assertEqual(dry_run(REPEAT="2", RUN_ID="s", SMOKE="1").returncode, 0)


class FullRun(unittest.TestCase):
    def test_a_sweep_records_itself(self):
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(tmp)
            # Set in the caller's shell; run.sh unsets them, and the record shows it.
            proc = box.run(REPEAT="1", RUN_ID="sweep-1", USE_SNAPSHOT_FOR_SYNC="false", PATH_INDEX="false")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.splitlines()[0], "RUN_ID=sweep-1", "the real run prints its RUN_ID first")
            record = box.record("sweep-1")
            self.assertEqual((record["runId"], record["repeat"], record["order"], record["verifyViews"], record["extra"]),
                             ("sweep-1", 1, "delta-first", True, False))
            self.assertEqual(record["swiftVersion"], "Swift version 6.2.4 (stand-in)")
            self.assertEqual(record["nodeVersion"], "v22.0.0")
            self.assertEqual(record["serverEnv"], {k: None for k in SERVER_ENV})
            self.assertIsNotNone(record["startedAt"])
            self.assertIsNotNone(record["endedAt"])
            self.assertEqual(len(record["cells"]), 12)
            self.assertEqual({c["status"] for c in record["cells"]}, {"measured-gate-passed"})
            self.assertEqual(record["cells"][1]["tag"], "rq1-rooms-full-snapshot")
            out = box.topic / "raw" / "sweep-1"
            self.assertTrue((out / "monsters-cap4-delta.json").exists())
            self.assertTrue((out / "monsters-cap4-delta.views.json").exists())
            self.assertFalse(list(out.glob(".views-*")), "captures are deleted once checked")

    def test_a_failed_gate_is_recorded_and_stops_the_sweep(self):
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(tmp)
            proc = box.run(REPEAT="1", RUN_ID="sweep-1", FAIL_GATE="monsters-cap4-delta")
            self.assertEqual(proc.returncode, 1)
            self.assertIn("verify-views failed for monsters-cap4-delta", proc.stderr)
            record = box.record("sweep-1")
            self.assertEqual([c["status"] for c in record["cells"]], ["measured-gate-passed"] * 2 + ["gate-failed"])
            self.assertIsNone(record["endedAt"])

    def test_an_existing_sweep_is_refused_and_a_redo_is_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(tmp)
            self.assertEqual(box.run(REPEAT="1", RUN_ID="sweep-1", VERIFY_VIEWS="0").returncode, 0)
            again = box.run(REPEAT="1", RUN_ID="sweep-1")
            self.assertEqual(again.returncode, 1)
            self.assertIn("raw/sweep-1/run.json exists", again.stderr)
            other = box.run(REPEAT="2", RUN_ID="sweep-1", OVERWRITE="1")
            self.assertEqual(other.returncode, 1)
            self.assertIn("is repeat 1, not 2", other.stderr)
            redo = box.run(REPEAT="1", RUN_ID="sweep-1", OVERWRITE="1", VERIFY_VIEWS="0")
            self.assertEqual(redo.returncode, 0, redo.stderr)
            self.assertIn(f"overwriting {box.topic}/raw/sweep-1/rq1-rooms-delta.json", redo.stderr)
            record = box.record("sweep-1")
            self.assertEqual(len(record["redos"]), 1)
            self.assertEqual(len(record["cells"]), 24)
            self.assertIn("rq1-rooms-delta.json", (box.topic / "raw" / "sweep-1" / "overwrites.log").read_text())

    def test_cell_files_without_a_record_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(tmp)
            out = box.topic / "raw" / "sweep-1"
            out.mkdir(parents=True)
            (out / "monsters-cap10-delta.log").write_text("earlier\n")
            proc = box.run(REPEAT="1", RUN_ID="sweep-1")
            self.assertEqual(proc.returncode, 1)
            self.assertIn(f"refusing to overwrite {out}/monsters-cap10-delta.log", proc.stderr)
            self.assertEqual((out / "monsters-cap10-delta.log").read_text(), "earlier\n")
            self.assertEqual(len(box.record("sweep-1")["cells"]), 4)


def fake_raw(cmd, rooms):
    return {
        "metadata": {
            "commandLine": cmd,
            "timestampUTC": "2026-11-07T00:00:00Z",
            "build": {"swiftVersion": "Swift version 6.2.4 (swift-6.2.4-RELEASE)", "configuration": "release"},
            "environment": {"cpuModel": "Test CPU", "osName": "Linux", "kernelVersion": "6.0"},
            "git": {"commit": "0123456789abcdef0123456789abcdef01234567", "branch": "main"},
        },
        "results": [{"rooms": r, "playersPerRoom": 5, "config": {"mode": "serial"},
                     "serial": {"bytesPerSync": 1000.0 * r, "avgCostPerSyncMs": 0.5}} for r in rooms],
    }


class Collect(unittest.TestCase):
    CMD = [BENCH, "--scalability", "--format", "messagepack-pathhash", "--parallel", "false",
           "--room-counts", "10,30", "--sync-strategy", "full-snapshot"]

    def sweep(self, topic, run_id, repeat, order="delta-first", dirty=False, **server_env):
        """A sweep recorded by runmeta.py. The scratch topic isn't a git checkout, so runmeta records
        no commit and no dirty flag; ``dirty`` sets the flag a checkout would have given (None keeps
        runmeta's)."""
        out = topic / "raw" / run_id
        env = {k: v for k, v in os.environ.items() if k not in SERVER_ENV}
        subprocess.run([sys.executable, "-I", str(topic / "runmeta.py"), "start", str(out), run_id, str(repeat),
                        order, "0", "", "0", "0"], check=True, capture_output=True, cwd=topic, env={**env, **server_env})
        if dirty is not None:
            record = json.loads((out / "run.json").read_text())
            record["git"] = {"commit": "0123456789abcdef0123456789abcdef01234567", "dirty": dirty}
            (out / "run.json").write_text(json.dumps(record))
        json.dump(fake_raw(self.CMD, [10, 30]), open(out / "rq1-rooms-full-snapshot.json", "w"))
        json.dump({"gate": "report"}, open(out / "rq1-rooms-full-snapshot.views.json", "w"))
        return out

    def collect(self, topic):
        return subprocess.run([sys.executable, "-I", str(topic / "collect.py")], capture_output=True, text=True, cwd=topic)

    def topic(self, tmp):
        topic = pathlib.Path(tmp) / "snapshot-baseline"
        topic.mkdir()
        for name in ("collect.py", "runmeta.py"):
            shutil.copy(TOPIC / name, topic / name)
        shutil.copy(TOPIC.parent / "serverenv.py", topic.parent / "serverenv.py")
        shutil.copy(TOPIC.parent / "gitstate.py", topic.parent / "gitstate.py")
        (topic / "raw").mkdir()
        json.dump(fake_raw(self.CMD, [10, 30]), open(topic / "raw" / "rq1-rooms-full-snapshot.json", "w"))
        return topic

    def test_a_sweep_whose_run_json_has_no_dirty_flag_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic = self.topic(tmp)
            self.sweep(topic, "sweep-1", 1, dirty=None)
            self.assertIsNone(json.loads((topic / "raw" / "sweep-1" / "run.json").read_text())["git"]["dirty"])
            proc = self.collect(topic)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(f"{pathlib.Path('raw', 'sweep-1', 'run.json')}: no git.dirty recorded (got None); "
                          "run the sweep with this topic's run.sh", proc.stderr)
            self.assertFalse(list((topic / "results").glob("*rep1.json")))

    def test_the_repeat_and_order_come_from_run_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic = self.topic(tmp)
            # A directory name that suggests another repeat must not matter.
            self.sweep(topic, "r1-looks-like-repeat-1", 2, "snapshot-first", USE_SNAPSHOT_FOR_SYNC="false")
            proc = self.collect(topic)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            names = sorted(p.name for p in (topic / "results").glob("*.json"))
            self.assertEqual(names, [
                "rooms-p5-r10-msgpack-full-rep2.json", "rooms-p5-r10-msgpack-full.json",
                "rooms-p5-r30-msgpack-full-rep2.json", "rooms-p5-r30-msgpack-full.json",
            ])
            rep = json.load(open(topic / "results" / "rooms-p5-r30-msgpack-full-rep2.json"))
            self.assertEqual((rep["params"]["repeat"], rep["params"]["order"], rep["params"]["sweep"]),
                             (2, "snapshot-first", "r1-looks-like-repeat-1"))
            self.assertEqual(rep["meta"]["source_file"], "r1-looks-like-repeat-1/rq1-rooms-full-snapshot.json")
            self.assertEqual(rep["metrics"]["bytes_per_sync"], 30000.0)
            # The sweep's recorded server environment is carried; the unrepeated record is the legacy path.
            self.assertEqual(rep["meta"]["server_env"], {**{k: None for k in SERVER_ENV}, "USE_SNAPSHOT_FOR_SYNC": "false"})
            self.assertEqual(rep["params"]["use_snapshot_for_sync"], "false")
            self.assertFalse(rep["meta"]["command"].startswith("USE_SNAPSHOT_FOR_SYNC"))
            record = json.load(open(topic / "results" / "rooms-p5-r30-msgpack-full.json"))
            self.assertNotIn("repeat", record["params"])
            self.assertIs(record["params"]["use_snapshot_for_sync"], False)
            self.assertIsNone(record["meta"]["server_env"])
            self.assertTrue(record["meta"]["command"].startswith("USE_SNAPSHOT_FOR_SYNC=false swift run"))

    def test_two_sweeps_claiming_one_repeat_need_one_superseded(self):
        with tempfile.TemporaryDirectory() as tmp:
            topic = self.topic(tmp)
            first = self.sweep(topic, "sweep-a", 1)
            self.sweep(topic, "sweep-b", 1)
            proc = self.collect(topic)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("repeat 1 is claimed by both sweep-a and sweep-b", proc.stderr)
            subprocess.run([sys.executable, "-I", str(topic / "runmeta.py"), "supersede", str(first), "redone as sweep-b"], check=True)
            proc = self.collect(topic)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rep = json.load(open(topic / "results" / "rooms-p5-r10-msgpack-full-rep1.json"))
            self.assertEqual(rep["params"]["sweep"], "sweep-b")


if __name__ == "__main__":
    unittest.main()
