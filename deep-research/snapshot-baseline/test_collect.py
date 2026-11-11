#!/usr/bin/env python3
"""collect.py takes each result's commit from its raw file, never from the checkout.

- Over the tracked record in raw/ (EncodingBenchmark files from before the path index), collect
  reproduces the tracked results/ byte for byte, at whatever commit it runs.
- A raw file keeps the commit its own metadata records (`git.commit`), abbreviated.
- A raw file with no recorded commit is refused.

Run: python3 test_collect.py (standard library only).
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

TOPIC = pathlib.Path(__file__).resolve().parent


def collect_in_copy(raw_files):
    """Runs a copy of collect.py over `raw_files` ({name: dict}) in a scratch topic; returns its results/."""
    tmp = pathlib.Path(tempfile.mkdtemp())
    topic = tmp / "snapshot-baseline"
    (topic / "raw").mkdir(parents=True)
    shutil.copy(TOPIC / "collect.py", topic / "collect.py")
    for name, data in raw_files.items():
        (topic / "raw" / name).write_text(json.dumps(data))
    done = subprocess.run([sys.executable, str(topic / "collect.py")], capture_output=True, text=True, cwd=tmp)
    return tmp, topic / "results", done


def raw_cell(commit):
    git = {} if commit is None else {"git": {"commit": commit, "branch": "main"}}
    return {
        "metadata": {
            "commandLine": ["EncodingBenchmark", "--scalability", "--format", "messagepack-pathhash",
                            "--players-per-room-list", "5", "--room-counts", "1", "--monster-cap", "4",
                            "--sync-strategy", "delta"],
            "timestampUTC": "2026-09-15T00:00:00Z",
            "build": {"swiftVersion": "Swift version 6.3.2", "configuration": "release"},
            **git,
        },
        "results": [{"rooms": 1, "playersPerRoom": 5,
                     "parallel": {"bytesPerSync": 828, "avgCostPerSyncMs": 0.4},
                     "serial": {"bytesPerSync": 828, "avgCostPerSyncMs": 0.4}}],
    }


def collect_sweep_in_copy(git):
    """A copy of collect.py over one run.sh sweep (raw/s1/run.json with ``git``, and one cell)."""
    tmp = pathlib.Path(tempfile.mkdtemp())
    topic = tmp / "snapshot-baseline"
    (topic / "raw" / "s1").mkdir(parents=True)
    shutil.copy(TOPIC / "collect.py", topic / "collect.py")
    (topic / "raw" / "s1" / "run.json").write_text(json.dumps({"runId": "s1", "repeat": 1, "order": "forward",
                                                                "superseded": None, "git": git, "serverEnv": {}}))
    (topic / "raw" / "s1" / "rq1-rooms.json").write_text(json.dumps(raw_cell("abcdef1234")))
    done = subprocess.run([sys.executable, str(topic / "collect.py")], capture_output=True, text=True, cwd=tmp)
    return tmp, topic / "results", done


class DirtyFlag(unittest.TestCase):
    def test_a_sweep_records_its_run_json_dirty_flag(self):
        tmp, results, done = collect_sweep_in_copy({"commit": "abcdef1234", "dirty": False})
        self.addCleanup(shutil.rmtree, tmp)
        self.assertEqual(done.returncode, 0, done.stderr)
        (result,) = [json.loads(p.read_text()) for p in results.glob("*.json")]
        self.assertIs(result["meta"]["git_dirty"], False)

    def test_a_sweep_without_the_flag_is_refused(self):
        for git in ({"commit": "abcdef1234"}, {"commit": "abcdef1234", "dirty": None}):
            with self.subTest(git):
                tmp, results, done = collect_sweep_in_copy(git)
                self.addCleanup(shutil.rmtree, tmp)
                self.assertNotEqual(done.returncode, 0)
                self.assertIn("run.json: no git.dirty recorded (got None); run the sweep with this topic's run.sh, "
                              "whose runmeta.py records git.dirty in run.json", done.stderr)
                self.assertEqual(list(results.glob("*.json")), [])


class Collect(unittest.TestCase):
    def test_the_tracked_record_is_reproduced_byte_for_byte(self):
        raws = {p.name: json.loads(p.read_text()) for p in sorted((TOPIC / "raw").glob("*.json"))}
        self.assertEqual(len(raws), 16)
        tmp, results, done = collect_in_copy(raws)
        try:
            self.assertEqual(done.returncode, 0, done.stderr)
            produced = {p.name: p.read_bytes() for p in results.glob("*.json")}
            tracked = {p.name: p.read_bytes() for p in (TOPIC / "results").glob("*.json") if "-rep" not in p.name}
            self.assertEqual(sorted(produced), sorted(tracked))
            for name in tracked:
                self.assertEqual(produced[name], tracked[name], f"{name} differs from the tracked result")
        finally:
            shutil.rmtree(tmp)

    def test_a_raw_file_keeps_its_own_commit(self):
        tmp, results, done = collect_in_copy({"monsters-cap4-delta.json": raw_cell("d2c647b4119e81c843d5c386e4788c24079bad92")})
        try:
            self.assertEqual(done.returncode, 0, done.stderr)
            (result,) = results.glob("*.json")
            self.assertEqual(json.loads(result.read_text())["meta"]["git_sha"], "d2c647b")
        finally:
            shutil.rmtree(tmp)

    def test_a_raw_file_without_a_commit_is_refused(self):
        tmp, results, done = collect_in_copy({"monsters-cap4-delta.json": raw_cell(None)})
        try:
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("no commit recorded", done.stderr)
            self.assertEqual(list(results.glob("*.json")), [])
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
