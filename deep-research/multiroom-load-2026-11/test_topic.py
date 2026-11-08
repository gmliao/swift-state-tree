#!/usr/bin/env python3
"""Tests for run.sh's plan (its dry run), with no build and no server.

Usage: python3 test_topic.py
"""
import json, os, pathlib, re, subprocess, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
MATRIX = [("preflight", 500, True)] + [(f"suite-{s}-{n}", n, True) for s in (1, 2, 3) for n in (100, 300, 500)] + [
    ("overhead-profiled", 500, True), ("overhead-unprofiled", 500, False)]


def dry_run(**env):
    full = dict(os.environ, DRY_RUN="1", RUN_ID="dry", **env)
    for key in ("RUNS", "ROOMS", "PRE_S", "STEADY_S", "POST_S", "SERVER_CPUS", "CLIENT_CPUS"):
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
            # The wait is the last step before its run: nothing else is planned between them.
            self.assertTrue(lines[i - 1].startswith("+ wait until TIME_WAIT <= 200"), lines[i - 1])
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
        for env in ({"RUNS": "nope"}, {"ROOMS": "x"}, {"ROOMS": "0"}, {"STEADY_S": "5s"}, {"RUN_ID": "a/b"}):
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


if __name__ == "__main__":
    unittest.main()
