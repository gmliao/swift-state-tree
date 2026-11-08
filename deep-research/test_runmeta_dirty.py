#!/usr/bin/env python3
"""Sweep outputs must not mark later sweeps dirty; uncommitted sources must.

Every topic's `runmeta.py start` records `git.dirty` from `git status --porcelain`, untracked
files included, and the topics' regenerate.py refuse a dirty run. So each topic's raw output
directory has to be gitignored: otherwise one sweep's files make every later sweep dirty.

- For every topic with a `run.sh` or a `data/<run-id>/` layout, a file in its output directory is
  ignored by the repository's .gitignore.
- The benchmarks' default result directories are ignored, and the EncodingBenchmark sweeps set
  BENCHMARK_RESULTS_DIR under their raw/.
- For every topic with a `runmeta.py`, in a scratch repository with the real .gitignore: a file
  under raw/ leaves `start` clean, and an untracked file elsewhere in the topic marks it dirty.

Run: python3 deep-research/test_runmeta_dirty.py (standard library and git only).
"""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
# Topics whose sweeps write under data/<run-id>/ instead of raw/<RUN_ID>/.
DATA_DIR_TOPICS = {"network-impairment-2026-11"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def output_dir(topic: pathlib.Path) -> str:
    return "data" if topic.name in DATA_DIR_TOPICS else "raw"


class SweepOutputsAreIgnored(unittest.TestCase):
    def test_every_sweep_output_directory_is_ignored(self):
        topics = [t for t in sorted(HERE.iterdir()) if (t / "run.sh").exists() or (t / "runmeta.py").exists()
                  or t.name in DATA_DIR_TOPICS]
        self.assertTrue(topics)
        for topic in topics:
            with self.subTest(topic.name):
                path = f"deep-research/{topic.name}/{output_dir(topic)}/20261108T000000Z-abc/run.json"
                self.assertEqual(git(REPO, "check-ignore", "-q", "--no-index", path).returncode, 0, f"{path} isn't ignored")

    def test_benchmark_default_result_directories_are_ignored(self):
        # The backstop for BENCHMARK_RESULTS_DIR, which the sweep scripts set under their raw/.
        for path in ("Examples/GameDemo/Sources/EncodingBenchmark/results/scalability-matrix-x.json",
                     "Examples/GameDemo/results/encoding-benchmark/x.json",
                     "Examples/GameDemo/results/server-loadtest/x.json"):
            with self.subTest(path):
                self.assertEqual(git(REPO, "check-ignore", "-q", "--no-index", path).returncode, 0, f"{path} isn't ignored")
        for topic in ("entity-delta-baseline", "snapshot-baseline", "visibility"):
            with self.subTest(topic):
                self.assertIn('export BENCHMARK_RESULTS_DIR="$OUT/', (HERE / topic / "run.sh").read_text())

    def test_runmeta_ignores_outputs_and_counts_untracked_sources(self):
        topics = sorted(t for t in HERE.iterdir() if (t / "runmeta.py").exists())
        self.assertTrue(topics)
        for topic in topics:
            with self.subTest(topic.name), tempfile.TemporaryDirectory() as tmp:
                repo = pathlib.Path(tmp)
                rel = pathlib.Path("deep-research") / topic.name
                (repo / rel).mkdir(parents=True)
                shutil.copy(REPO / ".gitignore", repo / ".gitignore")
                shutil.copy(topic / "runmeta.py", repo / rel / "runmeta.py")
                for args in (["init", "-q"], ["add", "-A"],
                             ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "t"]):
                    self.assertEqual(git(repo, *args).returncode, 0)

                def start(run_id):
                    out = repo / rel / output_dir(topic) / run_id
                    # start <dir> <run-id> <repeat> <order> <flag> <pin-cpus> <flag> <overwrite>
                    done = subprocess.run(["python3", str(rel / "runmeta.py"), "start", str(out), run_id, "1", "o", "1", "", "0", "0"],
                                          cwd=repo, capture_output=True, text=True)
                    self.assertEqual(done.returncode, 0, done.stderr)
                    return json.loads((out / "run.json").read_text())["git"]["dirty"]

                self.assertIs(start("s1"), False)
                (repo / rel / output_dir(topic) / "s1" / "cell.log").write_text("x")  # a sweep's own outputs
                self.assertIs(start("s2"), False, f"files under {output_dir(topic)}/ marked the tree dirty")
                (repo / rel / "new_script.py").write_text("x")  # an uncommitted source
                self.assertIs(start("s3"), True, "an untracked source didn't mark the tree dirty")


if __name__ == "__main__":
    unittest.main()
