#!/usr/bin/env python3
"""No tracked shell script under `pipefail` pipes into a reader that stops before its input ends.

`head -n N`, `grep -q`/`-m`/`-l`, `awk '... exit'` and `sed '...q'` exit once they have what they
need. The command writing into them then gets SIGPIPE, and under `set -o pipefail` the pipeline
fails with 141: under `set -e` the script stops with no message, and in an `if` a match reads as a
miss. It happens only when the writer still has output left, so small inputs hide it. Readers that
take the whole input are used instead: `sed -n '1,Np'` for head, and
`awk '/re/ {found = 1} END {exit !found}'` for grep -q.

A command that stops reading a *file* early (`grep -m1 pat file | ...`) is fine: nothing writes into it.

Run: python3 test_pipefail_readers.py (standard library only; needs git and bash).
"""
import pathlib
import re
import subprocess
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent

# A pipe (not ||) followed by a reader that can exit before its input ends. awk's `exit` counts
# only outside an END block.
EARLY = re.compile(
    r"""(?<!\|)\|(?!\|)\s*(
        head\b
      | grep\b[^|]*\s(-\w*[qml]\w*|--quiet|--silent|--max-count\S*|--files-with\S*)(\s|$)
      | awk\b(?![^|]*\bEND\s*\{[^|]*\bexit\b)[^|]*\bexit\b
      | sed\b[^|]*['"][^'"|]*[0-9/$]q\b
    )""",
    re.VERBOSE,
)


def offenders(text):
    if "pipefail" not in text:
        return []
    return [(i, line.strip()) for i, line in enumerate(text.splitlines(), 1)
            if not line.lstrip().startswith("#") and EARLY.search(line)]


def bash(script):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + script], capture_output=True, text=True)


# ~2 MB on stdout, far more than a pipe holds; the match is on the first line. (Not python: it
# ignores SIGPIPE and exits 1, which would hide the 141.)
PRODUCER = "{ echo CONFIG_X=m; seq 1 300000; }"


class Scripts(unittest.TestCase):
    def test_no_tracked_pipefail_script_pipes_into_an_early_exit_reader(self):
        files = subprocess.run(["git", "ls-files", "*.sh", "*.bash"], cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
        self.assertTrue(files)
        found = [f"{f}:{i}: {line}" for f in files for i, line in offenders((REPO / f).read_text(errors="replace"))]
        self.assertEqual(found, [], "early-exit reader in a pipefail pipeline:\n  " + "\n  ".join(found))

    def test_the_pattern_flags_each_form_and_passes_the_full_readers(self):
        bad = ["find . | sort | head -n 2", "x=$(lsof -t | head -1)", "zcat c.gz | grep -q '^A=m'",
               "cmd | grep -m1 x", "cmd | grep --quiet x", "cmd | awk 'NR==1 {print; exit}'", "cmd | sed '1q'",
               "cmd | grep -l x"]
        good = ["find . | sort | sed -n '1,2p'", "cmd | awk '/x/ {found = 1} END {exit !found}'",
                "grep -m1 'saved' log | sed 's/.*: //'", "a || head -n 1 f", "cmd | tail -n +2 | wc -l",
                "cmd | grep -oE 'v[0-9]+' | cut -d' ' -f2", "# cmd | head -1"]
        for line in bad:
            self.assertTrue(offenders("set -o pipefail\n" + line), line)
        for line in good:
            self.assertFalse(offenders("set -o pipefail\n" + line), line)
        self.assertFalse(offenders("cmd | head -1"), "a script without pipefail isn't affected")


class Idioms(unittest.TestCase):
    """The replacements hold under pipefail where the early readers fail."""

    def test_grep_q_fails_and_the_awk_reader_holds(self):
        self.assertEqual(bash(f"if {PRODUCER} | grep -q '^CONFIG_X=m'; then echo match; else echo miss; fi").stdout, "miss\n")
        for pattern, want in (("^CONFIG_X=m", "match\n"), ("^NOPE", "miss\n")):
            awk = "awk -v re='" + pattern + "' '$0 ~ re {found = 1} END {exit !found}'"
            self.assertEqual(bash(f"if {PRODUCER} | {awk}; then echo match; else echo miss; fi").stdout, want, pattern)

    def test_head_stops_the_script_and_sed_does_not(self):
        done = bash(f'x="$({PRODUCER} | head -n 1)"; echo "got $x"')
        self.assertEqual((done.returncode, done.stdout), (141, ""))
        done = bash(f'x="$({PRODUCER} | sed -n 1p)"; echo "got $x"')
        self.assertEqual((done.returncode, done.stdout), (0, "got CONFIG_X=m\n"))


if __name__ == "__main__":
    unittest.main()
