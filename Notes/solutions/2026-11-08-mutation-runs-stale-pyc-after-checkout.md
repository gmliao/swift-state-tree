---
module: deep-research
date: 2026-11-08
problem_type: testing_practice
component: mutation-checks
symptoms:
  - "A mutation run reports every mutant killed, but one test class fails on the unmutated tree when run alone"
  - "A test sees a constant the source no longer has (workers 1 where plan.py says 2) after a mutant was reverted with git checkout"
  - "Mutants finish implausibly fast"
root_cause: stale_pyc_after_same_size_restore_within_the_same_mtime_second
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - mutation
  - python
  - pycache
  - methodology
related:
  - "deep-research/network-impairment-2026-11/test_topic.py"
  - "deep-research/multiroom-load-2026-11/test_topic.py"
---

# Mutation runs: a stale `.pyc` after `git checkout` restores a same-size file within the same mtime second

## Problem

The deep-research topics' gates are checked by mutation: each mutant edits one rule in a script (`plan.py`, `regenerate.py`, `srpause.py`, …), runs the tests that should catch it, and reverts the file with `git checkout -- .`. Every mutant must fail some test. A control check found `test_topic.Plan` failing on the **unmutated** tree: it saw `workers: 1` where `plan.py` said `M_IMPAIRED_WORKERS = 2`. The 1 came from an earlier mutant. So a mutant can leave its edit behind for the mutants after it: a later mutant's tests fail because of the leftover, not because of its own edit, and it is counted as killed when it isn't.

## Root cause

Python caches each imported module's bytecode in `__pycache__/*.pyc`, keyed by the source's **mtime in whole seconds and its size**. A mutant that changes `= 2` to `= 1` keeps the file's size. When the tests import the mutated file, Python writes a `.pyc` for it. `git checkout` then restores the original in the same second: the size is the same, the mtime second is the same, and the next import trusts the stale `.pyc` and runs the mutant's code.

## Fix

In the mutation scripts:

- `export PYTHONDONTWRITEBYTECODE=1`, so no `.pyc` is written at all;
- remove every `__pycache__` before the first mutant;
- run the full tests on the unmutated tree first, as a **baseline that must pass**, and stop if it doesn't: a failing baseline makes every mutant look killed;
- when a mutant's text no longer matches the source, report it as **not applied**, never as killed or survived (a renamed variable silently disarms the mutant otherwise).

Rerun with these, the network-impairment and multiroom-load suites still killed every mutant, so the earlier counts stood, but they weren't proven until then.

## Prevention

- A mutation run is only evidence with a passing unmutated baseline and no bytecode cache. Count the mutants that didn't apply separately.
- A mutant "killed" by a test command that also fails without the mutant proves nothing. Check the command on the clean tree, or let the baseline do it.
- A mutant checked by grepping the source instead of by a behaviour test isn't a kill; leave it out and name the untested line instead.
- Python's mtime-and-size check can be fooled by any edit-and-restore within a second (a formatter, a generator, a test fixture rewriting a module): set `PYTHONDONTWRITEBYTECODE=1` where code is rewritten and re-imported in one process run.
