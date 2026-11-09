---
module: deep-research
date: 2026-11-09
problem_type: testing_practice
component: experiment-artifacts
symptoms:
  - "A topic's test fails right after its data commit lands, though nothing in the topic's code changed"
  - "Lists differ: ['2.5', '3.0'] != ['2.5']"
  - "results from 2 commits (...): one table is one commit's, in a test that builds its own repeats"
  - "Collected results carry the host checkout's absolute path (<root>/Examples/...) in meta.command, sweep.json or a toolchain string"
root_cause: collected_results_and_their_tests_tied_to_the_host_checkout_and_to_the_data_state
resolution_type: established_pattern
severity: medium
tags:
  - deep-research
  - collect
  - testing
  - provenance
  - methodology
related:
  - "5e84825f"
  - "a3276d69"
  - "0b45b54e"
  - "2026-11-08-moving-a-topics-results-breaks-the-topics-that-read-them"
---

# Collected results pinned to the host's checkout, and tests pinned to "no data yet"

## Problem

Two classes surfaced on the same night of data commits.

**(a) Tests that read a topic's committed data broke when that data landed.** Each test was correct while the topic had no measured data, and silently encoded that state:

- `multiroom-load-2026-11/test_topic.py` compared its fixture (built from `data/rerun/`, the pre-refreeze record) with the README's *first* "Server counters" table. That was the pre-refreeze table while the refreeze section read "Not run yet". Once the data commit filled the refreeze section, the first table was the new sweep's, and the expected counters no longer matched.
- `snapshot-baseline/test_regenerate.py` copied *all* of `results/` into a temporary topic beside its own synthetic repeats. The host's committed repeats came along, and the provenance line refused the mix of two commits.
- `replay-scale-fp-perturbation/test_topic.py` asserted that the committed batch formats were exactly `["2.5"]`; the 3.0 batch made it `["2.5", "3.0"]`.

No published number was wrong: `regenerate.py --check` was current throughout.

**(b) Collected results carried host absolute paths.** Run-time files record the paths a sweep ran with, in the checkout it ran in: recomputation-cost's `--record-dir`/`--stream-dir` in `meta.command`, multiroom-load-2026-11's `GAMESERVER_BIN` in `sweep.json` and `toolchain.txt`, external-input-failure's `external server binary …` in `client_toolchain`. The collectors copied them through.

## Root cause

(a) A test that reads committed `results/` or a README section by position is really a test of the data's current state. The data commit is a later change to that state, made by someone else, and the test has no way of telling "not run yet" from "the same thing".

(b) A collector treated run-time text as data to copy, with no notion of which checkout it came from. The first fix, which cut any absolute path at the first repository directory name it contained (`…/Examples/…`), made it worse in one way: a path outside the checkout (`/usr/local/lib/node_modules/npm/scripts/…`, `/srv/build/Tools/…`) came out looking checkout-relative, and the path guard could no longer see it.

## Fix

(a) In `0b45b54e`:

- the multiroom test names the section it reads ("Pre-refreeze record"), the one its fixture reproduces;
- the snapshot-baseline test copies only the pre-refreeze record;
- the replay-scale test checks every committed format, with 2.5 required among them.

(b) Commits `5e84825f` and `a3276d69`:

- The sweep's record keeps its checkout root (`runmeta.py`: `git.root`, from `git rev-parse --show-toplevel`). A record from before that field takes the root from the collector's explicit `--checkout-root`, and collect refuses without one.
- `deep-research/portable.py` strips exactly that root, as a whole leading path component. Every other absolute path stays as recorded.
- The root itself is dropped from the published `sweep.json`.
- recomputation-cost keeps its command line relative to the topic and refuses any other absolute argument.

## Prevention

- **A test uses its own fixtures, or names the section it reads.** Never index "the first table", copy all of `results/`, or pin the set of committed formats or files. Ask whether the test still passes after the topic's next data commit. If it can't, it is checking data, not code.
- **Strip only the recorded checkout root; leave every other path visible.** Never guess the root from a directory name inside the path. A path outside the checkout is a finding for the guard, not something to rewrite.
- Each affected topic has a test asserting that no string in a collected result is a host absolute path (`portable.absolute_paths`). `test_portable.py` pins the outside-the-checkout probes as must-stay-visible.
- **What caught each class:** the data-commit greps caught (b) before anything was pushed. CI caught (a): the "deep-research Python tests" step of Swift Build & Test's `examples` job (`.github/workflows/build-and-test.yml`) failed on all three tests. Main stayed red for six SHAs, about an hour, before anyone looked. The gap wasn't coverage. Data commits kept landing without each SHA's CI being checked first, and the step runs only in the `examples` job, after a long build, so its result arrives well after the next push.
- **Before the next push of a data series, check the previous SHA's Swift Build & Test.** Better still, run the topic's test files locally before the data commit: `git ls-files 'deep-research/*test_*.py' 'deep-research/**/test_*.py'`, each from its own directory, not only `regenerate.py --check`. The measurement host's data-commit procedure didn't include this step.
