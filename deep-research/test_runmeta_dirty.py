#!/usr/bin/env python3
"""Sweep outputs must not mark later sweeps dirty; uncommitted sources must.

Every topic's `runmeta.py start` records `git.dirty` by gitstate.py's rule: any tracked change,
or any untracked file outside the topic's own raw/, data/ and results/. The topics' regenerate.py
refuse a dirty run. The raw output directories are also gitignored, so they never show at all.

- For every topic with a `run.sh` or a `data/<run-id>/` layout, a file in its output directory is
  ignored by the repository's .gitignore.
- The benchmarks' default result directories are ignored, and the EncodingBenchmark sweeps set
  BENCHMARK_RESULTS_DIR under their raw/.
- For every topic with a `runmeta.py`, in a scratch repository with the real .gitignore: files
  under the topic's raw/, data/ and results/ (an earlier invocation's outputs) leave `start` clean;
  an untracked file elsewhere in the topic, a changed tracked file, and a changed tracked file
  under results/ each mark it dirty.

Run: python3 deep-research/test_runmeta_dirty.py (standard library and git only).
"""
import ast
import json
import sys
import pathlib
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import gitstate  # noqa: E402
# Topics whose sweeps write under data/<run-id>/ instead of raw/<RUN_ID>/.
DATA_DIR_TOPICS = {"network-impairment-2026-11"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def local_imports(script: pathlib.Path) -> list[pathlib.Path]:
    """The repository modules a script imports, by its sys.path: its own directory and deep-research/."""
    names = set()
    for node in ast.walk(ast.parse(script.read_text())):
        if isinstance(node, ast.Import):
            names.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            names.add(node.module.split(".")[0])
    found = []
    for name in sorted(names):
        for d in (script.parent, HERE):
            if (d / f"{name}.py").exists():
                found.append(d / f"{name}.py")
                break
    return found


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
                (repo / rel / "results").mkdir(parents=True)
                (repo / rel / "results" / "tracked.json").write_text("{}")  # a committed result
                shutil.copy(REPO / ".gitignore", repo / ".gitignore")
                shutil.copy(topic / "runmeta.py", repo / rel / "runmeta.py")
                # The modules runmeta imports (serverenv.py), at the same place relative to it.
                for module in local_imports(topic / "runmeta.py"):
                    dest = repo / module.relative_to(REPO)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy(module, dest)
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
                # An earlier invocation's ingested results and run data, untracked (network-impairment's
                # step 2 before its SR step), in a new subdirectory too.
                (repo / rel / "results" / "sweep-M-P0-r1.json").write_text("{}")
                (repo / rel / "results" / "sub").mkdir()
                (repo / rel / "results" / "sub" / "x.json").write_text("{}")
                (repo / rel / "data").mkdir(exist_ok=True)
                (repo / rel / "data" / "x.log").write_text("x")
                self.assertIs(start("s2b"), False, "untracked files under results/ or data/ marked the tree dirty")
                (repo / rel / "new_script.py").write_text("x")  # an uncommitted source
                self.assertIs(start("s3"), True, "an untracked source didn't mark the tree dirty")
                (repo / rel / "new_script.py").unlink()
                (repo / rel / "results" / "tracked.json").write_text('{"x": 1}')  # a changed committed result
                self.assertIs(start("s4"), True, "a changed tracked file under results/ didn't mark the tree dirty")
                git(repo, "checkout", "--", ".")
                (repo / rel / "runmeta.py").write_text((repo / rel / "runmeta.py").read_text() + "\n# x\n")
                self.assertIs(start("s5"), True, "a changed tracked source didn't mark the tree dirty")


class GitState(unittest.TestCase):
    def test_entries_skip_a_renames_source_path(self):
        z = "R  deep-research/t/new.py\0deep-research/t/old.py\0?? deep-research/t/results/a.json\0 M x.py\0"
        self.assertEqual(gitstate.entries(z), [("R ", "deep-research/t/new.py"), ("??", "deep-research/t/results/a.json"),
                                               (" M", "x.py")])

    def test_another_topics_output_directory_is_not_this_topics(self):
        # Paths are matched as the topic's own prefix: deep-research/t2/results/ isn't t's.
        self.assertTrue(all(not p.startswith(("deep-research/t/raw/", "deep-research/t/data/", "deep-research/t/results/"))
                            for _, p in gitstate.entries("?? deep-research/t2/results/a.json\0")))


if __name__ == "__main__":
    unittest.main()
