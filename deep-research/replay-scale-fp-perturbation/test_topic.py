#!/usr/bin/env python3
"""Tests for the batch path: scripts/run-batch.sh (dry run, and a whole batch against a stand-in
ReevaluationRunner), scripts/summarize.py and regenerate.py's per-format batch checks.

Usage: python3 test_topic.py   (no build needed)
"""
import copy, json, os, pathlib, shutil, subprocess, sys, tempfile, unittest

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
sys.path.insert(0, str(TOPIC / "scripts"))
import regenerate  # noqa: E402
import summarize  # noqa: E402

RUN_BATCH = TOPIC / "scripts" / "run-batch.sh"

# A stand-in ReevaluationRunner: --record writes bytes fixed by the seed (or by $STUB_NOISE too,
# to fake a nondeterministic recording) and runs $STUB_HOOK (to change the tree mid-batch);
# --input --verify prints the lines summarize.py reads.
STUB = r'''#!/usr/bin/env bash
seed=0; ticks=0; out=""; mode=""
while [ $# -gt 0 ]; do case "$1" in
  --record) mode=record; shift ;; --verify) mode=verify; shift ;; --input) shift 2 ;;
  --seed-id) seed=$2; shift 2 ;; --ticks) ticks=$2; shift 2 ;; --output) out=$2; shift 2 ;;
  *) shift 2 ;; esac; done
if [ "$mode" = record ]; then eval "${STUB_HOOK:-}"; printf 'SSTR seed %s %s' "$seed" "${STUB_NOISE:-}$RANDOM_PART" > "$out"; exit 0; fi
echo "📼 Record: ${STUB_FORMAT:-3.0}, complete"
echo "   Total Ticks: 1200"; echo "   Actions: 0"; echo "   Client Events: 300"; echo "   Ticks with State Hash: 1200"
echo "✅ Verified state hashes: computed hashes match recorded ground truth"
echo "✅ Verified state hashes: identical across two re-evaluation runs"
'''


def git_repo(repo, dirty=False):
    """A checkout for run-batch.sh to record: committed, its build and outputs ignored as in the real one."""
    (repo / ".gitignore").write_text(".build/\nout/\nresults/\nbin/\nstub/\n")
    for args in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "t"]):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
    if dirty:
        (repo / "uncommitted.py").write_text("x")
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True).stdout.strip()


# A stand-in swift: `build` (run in Examples/GameDemo) installs the stand-in runner into
# .build/release, so a batch has a runner only when run-batch.sh built it.
SWIFT_STUB = r'''#!/usr/bin/env bash
[ "$1" = build ] && [ "$(basename "$PWD")" = GameDemo ] || exit 3
mkdir -p .build/release && cp "$(dirname "$0")/ReevaluationRunner" .build/release/ReevaluationRunner
'''


def write_stub(repo):
    stub = repo / "stub"
    stub.mkdir()
    (repo / "Examples" / "GameDemo").mkdir(parents=True)
    for name, text in (("ReevaluationRunner", STUB), ("swift", SWIFT_STUB)):
        (stub / name).write_text(text)
        (stub / name).chmod(0o755)


def run_batch(repo, out, path=None, **env):
    env.setdefault("SWIFT", str(repo / "stub" / "swift"))
    e = dict(os.environ, **env)
    if path is not None:
        e["PATH"] = path
    return subprocess.run(["bash", str(RUN_BATCH), str(repo), str(out)], capture_output=True, text=True, env=e)


class RunBatch(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_dry_run_lists_every_seed_recorded_twice(self):
        p = run_batch(self.tmp, self.tmp / "out", DRY_RUN="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.count("--verify"), 41)
        self.assertEqual(p.stdout.count("--record "), 82)
        self.assertEqual(p.stdout.count("/records/s"), 82)  # one record + one verify per seed
        self.assertEqual(p.stdout.count("/records-2/s"), 41)
        self.assertIn("source.json", p.stdout)
        self.assertIn("build -c release --product ReevaluationRunner", p.stdout)
        self.assertIn("--seed-id 202 --players 5 --move-every 20 --ticks 12000", p.stdout)
        self.assertFalse([l for l in p.stdout.splitlines() if "--output" in l and l.endswith(".json")])
        self.assertFalse((self.tmp / "out").exists())

    def test_dry_run_options(self):
        p = run_batch(self.tmp, self.tmp / "out", DRY_RUN="1", TWICE="0", SEEDS="3 111")
        self.assertEqual(p.stdout.count("--verify"), 2)
        self.assertEqual(p.stdout.count("/records-2/"), 0)
        self.assertEqual(run_batch(self.tmp, self.tmp / "out", TWICE="2").returncode, 2)
        self.assertEqual(subprocess.run(["bash", str(RUN_BATCH), str(self.tmp)], capture_output=True).returncode, 2)

    def test_a_whole_batch_against_the_stand_in(self):
        write_stub(self.tmp)
        head = git_repo(self.tmp)
        out = self.tmp / "out"
        p = run_batch(self.tmp, out)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("done: 41 recordings, record failures 0, verify failures 0, second recordings differing 0", p.stdout)
        self.assertEqual(json.loads((out / "source.json").read_text()),
                         {"commit": head, "dirty": False, "status": [], "built": True,
                          "commitAtEnd": head, "dirtyAtEnd": False, "statusAtEnd": []})
        doc, sums = summarize.summarize(out, "host", "Swift 6.2.4", "x86_64")
        self.assertEqual((doc["meta"]["git_sha"], doc["meta"]["git_dirty"]), (head[:8], False))
        self.assertEqual(doc["meta"]["record_format"], "3.0")
        self.assertEqual(len(doc["recordings"]), 41)
        self.assertTrue(all(r["second_recording_identical"] for r in doc["recordings"]))
        self.assertIn("  s202.sstr\n", sums)
        results = self.tmp / "results"
        results.mkdir()
        (results / "batch-3.0-SHA256SUMS.txt").write_text(sums)
        (results / "batch-3.0-x86_64.json").write_text(json.dumps(doc))
        batches = regenerate.load_batches(results)
        self.assertEqual(list(batches), ["3.0"])
        self.assertEqual(regenerate.check_batches("3.0", batches["3.0"], results), [])
        self.assertIn("| host | x86_64 | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 0 |", regenerate.batch_table(batches["3.0"]))
        # The same batch again over an existing out-dir is refused.
        self.assertNotEqual(run_batch(self.tmp, out).returncode, 0)

    def test_a_dirty_tree_is_recorded_and_refused_by_summarize(self):
        write_stub(self.tmp)
        git_repo(self.tmp, dirty=True)
        out = self.tmp / "out"
        p = run_batch(self.tmp, out, SEEDS="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        record = json.loads((out / "source.json").read_text())
        self.assertEqual((record["dirty"], record["status"]), (True, ["?? uncommitted.py"]))
        with self.assertRaises(SystemExit) as refused:
            summarize.summarize(out, "host", "Swift 6.2.4", "x86_64")
        self.assertIn("dirty tree", str(refused.exception))

    def test_the_runner_is_built_by_the_batch(self):
        write_stub(self.tmp)
        git_repo(self.tmp)
        p = run_batch(self.tmp, self.tmp / "out", SEEDS="1", SWIFT="false")
        self.assertEqual(p.returncode, 1)
        self.assertIn("building ReevaluationRunner failed", p.stderr)
        self.assertNotIn("built", json.loads((self.tmp / "out" / "source.json").read_text()))
        self.assertFalse((self.tmp / "out" / "summary.tsv").exists())

    def test_a_tree_that_changes_while_the_batch_runs_is_refused(self):
        for hook, text in ((f"git -C {self.tmp} -c user.name=t -c user.email=t@t commit -q --allow-empty -m mid", "commit changed"),
                           (f"touch {self.tmp}/new_source.py", "dirty after the last seed")):
            with self.subTest(text):
                tmp = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
                write_stub(tmp)
                git_repo(tmp)
                out = tmp / "out"
                p = run_batch(tmp, out, SEEDS="1", STUB_HOOK=hook.replace(str(self.tmp), str(tmp)))
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                with self.assertRaises(SystemExit) as refused:
                    summarize.summarize(out, "host", "Swift 6.2.4", "x86_64")
                self.assertIn(text, str(refused.exception))

    def test_an_out_dir_in_the_tree_must_be_ignored(self):
        write_stub(self.tmp)
        git_repo(self.tmp)
        p = run_batch(self.tmp, self.tmp / "batch-out", SEEDS="1")
        self.assertEqual(p.returncode, 2)
        self.assertIn("not gitignored", p.stderr)
        self.assertFalse((self.tmp / "batch-out").exists())
        outside = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, outside)
        self.assertEqual(run_batch(self.tmp, outside / "out", SEEDS="1").returncode, 0)

    def test_a_directory_outside_git_is_refused_before_recording(self):
        write_stub(self.tmp)
        p = run_batch(self.tmp, self.tmp / "out", SEEDS="1", GIT_CEILING_DIRECTORIES=str(self.tmp.parent))
        self.assertEqual(p.returncode, 1)
        self.assertIn("must record its commit", p.stderr)
        self.assertFalse((self.tmp / "out" / "records").exists())

    def test_hashes_without_sha256sum_or_shasum(self):
        write_stub(self.tmp)
        git_repo(self.tmp)
        tools = self.tmp / "bin"
        tools.mkdir()
        for t in ("bash", "awk", "cut", "wc", "tr", "seq", "mkdir", "python3", "cat", "git", "cp", "dirname", "basename", "env"):
            (tools / t).symlink_to(shutil.which(t))
        p = run_batch(self.tmp, self.tmp / "out", path=str(tools), SEEDS="1 2")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        rows = [l.split("\t") for l in (self.tmp / "out" / "summary.tsv").read_text().splitlines()]
        import hashlib
        want = hashlib.sha256((self.tmp / "out" / "records" / "s1.sstr").read_bytes()).hexdigest()
        self.assertEqual((rows[0][6], rows[0][7]), (want, want))

    def test_a_nondeterministic_recording_fails_the_batch(self):
        write_stub(self.tmp)
        git_repo(self.tmp)
        stub = self.tmp / "stub" / "ReevaluationRunner"
        stub.write_text(stub.read_text().replace('$RANDOM_PART', '$(basename "$(dirname "$out")")'))
        p = run_batch(self.tmp, self.tmp / "out", SEEDS="1")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("second recordings differing 1", p.stdout)


class Summarize(unittest.TestCase):
    def batch_dir(self, formats=("3.0", "3.0"), source=None):
        d = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        good = "0123456789abcdef0123456789abcdef01234567"
        source = ({"commit": good, "dirty": False, "status": [], "built": True, "commitAtEnd": good, "dirtyAtEnd": False}
                  if source is None else source)
        if source != "missing":
            (d / "source.json").write_text(json.dumps(source))
        (d / "logs").mkdir()
        (d / "records").mkdir()
        rows = []
        for i, fmt in enumerate(formats, 1):
            (d / "records" / f"s{i}.sstr").write_bytes(b"x")
            (d / "logs" / f"s{i}.verify.log").write_text(
                (f"📼 Record: {fmt}, complete\n" if fmt else "") + "   Total Ticks: 1200\n")
            rows.append(f"{i}\t5\t20\t1200\t0\t0\th{i}\t" + ("h9" if i == 2 else f"h{i}"))
        (d / "summary.tsv").write_text("\n".join(rows) + "\n")
        return d

    def test_format_names_and_second_recordings(self):
        doc, sums = summarize.summarize(self.batch_dir(), "h", "sw", "a")
        self.assertEqual(doc["meta"]["git_sha"], "01234567")
        self.assertEqual(doc["meta"]["record_format"], "3.0")
        self.assertEqual(sums, "h1  s1.sstr\nh2  s2.sstr\n")
        self.assertEqual([r["second_recording_identical"] for r in doc["recordings"]], [True, False])

    def test_mixed_or_missing_formats_are_refused(self):
        for formats in (("3.0", "2.5"), ("3.0", None)):
            with self.subTest(formats), self.assertRaises(SystemExit):
                summarize.summarize(self.batch_dir(formats), "h", "sw", "a")

    def test_a_missing_dirty_or_malformed_source_is_refused(self):
        for source, text in (("missing", "isn't recorded"), ({"commit": "abc", "dirty": False}, "no commit recorded"),
                             ({"commit": "0" * 40, "dirty": True, "status": [" M x"]}, "dirty tree"),
                             ({"commit": "0" * 40}, "dirty tree"),
                             ({"commit": "0" * 40, "dirty": False, "commitAtEnd": "0" * 40, "dirtyAtEnd": False}, "wasn't built"),
                             ({"commit": "0" * 40, "dirty": False, "built": True, "dirtyAtEnd": False}, "commit changed"),
                             ({"commit": "0" * 40, "dirty": False, "built": True, "commitAtEnd": "0" * 40}, "dirty after")):
            with self.subTest(source), self.assertRaises(SystemExit) as refused:
                summarize.summarize(self.batch_dir(source=source), "h", "sw", "a")
            self.assertIn(text, str(refused.exception))


class CheckBatches(unittest.TestCase):
    def setUp(self):
        self.results = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.results)
        rec = {"seed": 0, "players": 5, "move_every": 20, "ticks": 1200, "ticks_with_state_hash": 1200,
               "actions": 0, "client_events": 300, "record_exit": 0, "verify_exit": 0, "mismatch_ticks": 0,
               "verified_vs_recorded": True, "verified_run1_vs_run2": True, "sha256": "h",
               "second_recording_identical": True}
        sums = "h  s.sstr\n"
        (self.results / "batch-3.0-SHA256SUMS.txt").write_text(sums)
        import hashlib
        self.batch = {"_file": "batch-3.0-x86_64.json",
                      "meta": {"record_format": "3.0", "sha256sums_sha256": hashlib.sha256(sums.encode()).hexdigest(),
                               "host": "h", "arch": "x86_64", "swift": "6.2.4", "build": "release",
                               "git_sha": "01234567", "git_dirty": False},
                      "recordings": [dict(rec, seed=n) for n in range(41)]}

    def errors(self, edit=None, fmt="3.0"):
        b = copy.deepcopy(self.batch)
        if edit:
            edit(b)
        return regenerate.check_batches(fmt, [b], self.results)

    def test_a_complete_batch_passes(self):
        self.assertEqual(self.errors(), [])

    def test_refusals(self):
        cases = (
            (lambda b: b["recordings"].pop(), "40 recordings, the batch is 41"),
            (lambda b: b["recordings"][3].update(verify_exit=1), "nonzero verify exit for seeds [3]"),
            (lambda b: b["recordings"][4].update(record_exit=1), "nonzero record exit for seeds [4]"),
            (lambda b: b["recordings"][5].update(second_recording_identical=False), "second recording differs for seeds [5]"),
            (lambda b: b["recordings"][6].pop("second_recording_identical"), "no second recording for seeds [6]"),
            (lambda b: b["meta"].update(sha256sums_sha256="0"), "differs from batch-3.0-SHA256SUMS.txt"),
            (lambda b: b["meta"].update(record_format="3.1"), "record_format 3.1, its name says 3.0"),
            (lambda b: b["meta"].update(git_dirty=True), "needs the clean commit"),
            (lambda b: b["meta"].pop("git_dirty"), "needs the clean commit"),
            (lambda b: b["meta"].update(git_sha=None), "needs the clean commit"),
        )
        for edit, text in cases:
            with self.subTest(text):
                self.assertTrue(any(text in e for e in self.errors(edit)), self.errors(edit))

    def test_a_format_without_its_sums_list_is_refused(self):
        self.assertEqual(self.errors(fmt="3.1")[0], "batch-3.1-SHA256SUMS.txt missing")

    def test_the_committed_2_5_batches_still_check(self):
        batches = regenerate.load_batches()
        self.assertEqual(list(batches), ["2.5"])
        self.assertEqual(regenerate.check_batches("2.5", batches["2.5"]), [])


if __name__ == "__main__":
    unittest.main()
