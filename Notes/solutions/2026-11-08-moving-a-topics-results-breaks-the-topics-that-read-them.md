---
module: deep-research
date: 2026-11-08
problem_type: gotcha
component: experiment-artifacts
symptoms:
  - "regenerate.py --check fails in a topic nobody touched: expected exactly one run for {...}, found 0"
  - "A topic's results/ moved or renamed, and another topic's tables lose their comparison rows"
root_cause: cross_topic_reader_of_a_moved_results_directory
resolution_type: established_pattern
severity: low
tags:
  - deep-research
  - regenerate
  - verification
  - methodology
related:
  - "9ae202a7"
  - "41290874"
---

# Moving a topic's results breaks the topics that read them

## Problem

The wire-form ablation in `deep-research/single-room-entity-scaling/` (`9ae202a7`) moved that topic's 2026-08-31 results from `results/` to `results/pre-refreeze/`, so the new `results/` could hold the ablation. That topic's own tests and `regenerate.py --check` passed, and the commit went to main. `deep-research/snapshot-baseline/regenerate.py` also reads those results (`ARCHIVE`, its drift check against the archived single-room delta cells), and its `--check` failed from then on with `expected exactly one run for {...}, found 0` until `41290874` pointed `ARCHIVE` at the new place.

## Root cause

A topic's `results/` is an input not only to its own `regenerate.py`. Comparisons across topics read another topic's directory by path, and nothing but a full sweep of every topic's `--check` notices when that path goes away. The change was verified topic by topic: the moved one, and the ones whose code it touched.

## Fix

`snapshot-baseline`'s `ARCHIVE` reads `single-room-entity-scaling/results/pre-refreeze/` (the same runs, both knobs off like its own record, so the comparison is unchanged).

## Prevention

- Before moving or renaming anything under a topic's `results/` or `raw/`, `git grep -n '<topic name>' -- ':!deep-research/<topic name>'` and fix every reader in the same commit.
- After any change to `deep-research/`, run every topic's check, not only the touched ones:
  `for d in deep-research/*/; do [ -f "$d/regenerate.py" ] || continue; (cd "$d" && python3 regenerate.py --check >/dev/null) || echo "FAIL $d"; done`
