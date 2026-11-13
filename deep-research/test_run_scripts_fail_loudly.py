#!/usr/bin/env python3
"""The topics' run.sh helpers stop the sweep with a message, never silently.

Under `set -euo pipefail`, `x=$(helper …)` stops the script when the helper fails, and prints
nothing unless the helper does. These tests run each helper, extracted from every run.sh that has
it, under the scripts' own options:
- `saved_file <log>`: the result file named in a benchmark log; a log without the line, or no log;
- the default `RUN_ID`, which records the commit: outside a git checkout;
- recomputation-cost's `first_records` and `replay`: a missing or short records directory.

Run: python3 test_run_scripts_fail_loudly.py (standard library only; needs bash and git).
"""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SAVED_FILE = ["entity-delta-baseline", "recomputation-cost", "single-room-entity-scaling", "snapshot-baseline", "visibility"]
RUN_ID = SAVED_FILE + ["external-input-failure", "multiroom-load-2026-11"]


def block(script, start, end="^}"):
    text = (HERE / script).read_text(encoding="utf-8")
    m = re.search(rf"(?ms)^{re.escape(start)}.*?{end}$", text)
    assert m, f"{script}: no block starting {start!r}"
    return m.group(0)


def bash(body, *args, env=None):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + body, "bash", *map(str, args)],
                          capture_output=True, text=True, env=env, encoding="utf-8")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)


class SavedFile(Base):
    CALL = 'f() { local saved; saved=$(saved_file "$1"); echo "got $saved"; }\nf "$1"\necho after\n'

    def test_each_run_sh_returns_the_named_file(self):
        log = self.tmp / "run.log"
        log.write_text("warm-up\n📁 Results saved to: /out/a: b.json\nResults saved to: /out/later.json\n", encoding="utf-8")
        for topic in SAVED_FILE:
            with self.subTest(topic):
                done = bash(block(f"{topic}/run.sh", "saved_file() {") + "\n" + self.CALL, log)
                self.assertEqual((done.returncode, done.stdout), (0, "got /out/a: b.json\nafter\n"), done.stderr)

    def test_a_miss_stops_the_sweep_naming_the_log(self):
        empty = self.tmp / "empty.log"
        empty.write_text("the benchmark crashed\n", encoding="utf-8")
        for topic in SAVED_FILE:
            for log in (empty, self.tmp / "missing.log"):
                with self.subTest(topic=topic, log=log.name):
                    done = bash(block(f"{topic}/run.sh", "saved_file() {") + "\n" + self.CALL, log)
                    self.assertNotEqual(done.returncode, 0)
                    self.assertEqual(done.stdout, "")
                    self.assertIn(f"no 'Results saved to:' line in {log}", done.stderr)


class RunId(Base):
    def run_id(self, topic, top):
        body = f'TOPIC="$1"; RUN_ID=""\n{block(f"{topic}/run.sh", "if [ -z \"$RUN_ID\" ]; then", "^fi")}\necho "id $RUN_ID"\n'
        env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(self.tmp))
        return bash(body, top, env=env)

    def test_outside_git_stops_with_a_message(self):
        for topic in RUN_ID:
            with self.subTest(topic):
                done = self.run_id(topic, self.tmp)
                self.assertNotEqual(done.returncode, 0)
                self.assertEqual(done.stdout, "")
                self.assertIn("isn't in a git checkout: a run records its commit", done.stderr)

    def test_inside_git_names_the_commit(self):
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, capture_output=True, text=True, check=True, encoding="utf-8").stdout.strip()
        for topic in RUN_ID:
            with self.subTest(topic):
                done = self.run_id(topic, HERE / topic)
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertRegex(done.stdout, rf"^id \d{{8}}T\d{{6}}Z-{head}\n$")


class Records(Base):
    """recomputation-cost: replay and the cost pass take their records through first_records."""

    def functions(self):
        script = "recomputation-cost/run.sh"
        return "\n".join(block(script, name) for name in ("first_records() {", "replay() {"))

    def call(self, what, cell):
        stub = 'DRY_RUN=0; REPLAY=true; OPEN_REPEAT=1; PIN=()\nx_out() { echo "ran $*"; }\n'
        return bash(stub + self.functions() + "\n" + what + "\necho after\n", cell)

    def records(self, n):
        cell = self.tmp / f"cell{n}"
        (cell / "records").mkdir(parents=True)
        for i in range(n):
            (cell / "records" / f"s{i}.sstr").touch()
        return cell

    def test_a_missing_or_short_records_dir_stops_with_a_message(self):
        for what, cell, text in (('rec="$(first_records "$1" 1)"', self.tmp / "none", "can't list"),
                                 ('rec="$(first_records "$1" 1)"', self.records(0), "fewer than 1 records"),
                                 ('replay "$1"', self.tmp / "none", "can't list"),
                                 ('replay "$1"', self.records(1), "fewer than 2 records")):
            with self.subTest(what=what, cell=cell.name):
                done = self.call(what, cell)
                self.assertNotEqual(done.returncode, 0)
                self.assertEqual(done.stdout, "")
                self.assertIn(text, done.stderr)

    def test_enough_records_go_through(self):
        cell = self.records(3)
        done = self.call('replay "$1"', cell)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.count("ran "), 6)  # replay, verify, open for each of the first two
        self.assertNotIn("s2.sstr", done.stdout)


if __name__ == "__main__":
    unittest.main()
