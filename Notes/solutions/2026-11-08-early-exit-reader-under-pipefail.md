---
module: shell scripts (deep-research run.sh, ws-loadtest scripts, Tools benchmarks)
date: 2026-11-08
problem_type: tooling_trap
component: shell-pipelines
symptoms:
  - "a sweep stops with exit 141 and no error message"
  - "the last line is a cell's done line; the next cell is incomplete"
  - "an `if cmd | grep -q pat` check is skipped although the pattern is there"
root_cause: a_reader_that_exits_early_sends_sigpipe_to_its_writer_and_pipefail_reports_it
resolution_type: code_fix
severity: high
tags:
  - shell
  - pipefail
  - sigpipe
  - measurement
  - methodology
related:
  - "2026-11-08 refreeze, topic 5 (recomputation-cost)"
---

# A reader that stops early fails the pipeline under `pipefail`

## Problem

The recomputation-cost sweep stopped partway through the cost pass with exit 141 and no message. `check_records` takes the first record with `rec="$(first_records "$dir" 1)"`, and `first_records` was `find … | sort | head -n "$2"`. The script runs under `set -euo pipefail`.

## Root cause

`head -n 1` exits once it has printed its line. If `sort` still has output to write, that write raises SIGPIPE and `sort` dies with 141. `pipefail` makes the pipeline's status 141, and `set -e` stops the script at the assignment. Nothing prints, because nothing failed in the usual sense.

The failure depends on size. A listing that fits in the pipe buffer is written before `head` exits, so the smoke runs and the first cells passed. The cost cells have thousands of records, and their listing doesn't fit. It is deterministic once the output is large: a 20,000-name listing gives 141 every time.

The same class appears in an `if` as a wrong answer, not a stop. In `zcat /proc/config.gz | grep -q "^CONFIG_X=m"`, `grep -q` exits at the match, `zcat` gets SIGPIPE, and the pipeline fails exactly when the pattern is found. That made the module check in `impair.sh` silently skip itself.

## Fix

Use readers that consume all of their input:
- `sed -n "1,${n}p"` instead of `head -n "$n"`.
- `awk '/re/ {found = 1} END {exit !found}'` (or `awk -v re=…`) instead of `grep -q`.

This applies to every tracked script that sets `pipefail`: recomputation-cost and multiroom-load `run.sh`, ws-loadtest `impair.sh` and `run-ws-loadtest.sh`, and the three Tools transport benchmarks.

Tests:
- `recomputation-cost/test_topic.py` runs `first_records` on a 20,000-record listing. It also shows that the old form exits 141 there.
- `deep-research/test_pipefail_readers.py` fails on any tracked `pipefail` script that pipes into `head`, `grep -q/-m/-l`, an `awk` with `exit` outside `END`, or `sed …q`. It also checks the two replacements against a 2 MB producer.

## Prevention

- **Under `pipefail`, never pipe into a reader that stops before its input ends.** Read everything, and select inside the reader.
- A command that stops reading a *file* early (`grep -m1 pat file | …`) is fine, because nothing writes into it.
- Test such a pipeline with output larger than a pipe buffer (64 KiB), not with smoke-sized input.
- A Python producer hides the 141. Python ignores SIGPIPE and exits 1 with `BrokenPipeError`. Use `seq` or another C tool when reproducing the problem.
- **A helper used as `x=$(helper …)` under `set -e` must say why it fails.** The assignment stops the script silently otherwise: `saved_file` (`grep -m1` with no match) and the default `RUN_ID` (`git rev-parse` outside a checkout) both did. Each now prints what is missing and exits; `deep-research/test_run_scripts_fail_loudly.py` runs them from every run.sh.
- **`for x in $(helper)` ignores the helper's failure**: the loop runs zero times and the script goes on. Assign first (`xs=$(helper)`), then loop.
- `test_pipefail_readers.py` lists the forms it doesn't catch (loops that `break`, programs beyond the listed readers, workflow YAML).
