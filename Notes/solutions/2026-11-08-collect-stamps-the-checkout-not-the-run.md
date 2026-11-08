---
module: deep-research (snapshot-baseline collect.py)
date: 2026-11-08
problem_type: measurement_pitfall
component: experiment-provenance
symptoms:
  - "wire form missing: pathIndex not recorded although commit <HEAD> contains it"
  - "collect.py rewrote tracked results/*.json"
  - "every results file is refused right after a clean sweep"
root_cause: converter_took_the_commit_from_the_checkout_head_instead_of_the_run_record
resolution_type: code_fix
severity: medium
tags:
  - measurement
  - provenance
  - collect
  - regenerate
  - methodology
related:
  - "2026-11-08 refreeze, topic 2"
---

# A converter that stamps the checkout's commit misattributes every older run

## Problem

The refreeze's snapshot-baseline sweeps all passed (clean tree, verify-views green), and then `collect.py` and `regenerate.py` refused every result: `pathIndex not recorded although commit aaf4f518 contains it`. The refused files weren't the new sweeps. They were the topic's published record, 16 raw files tracked in `raw/`, measured in September before the path index existed. `collect.py` had rewritten all 34 of their tracked results.

## Root cause

`collect.py` set each result's `git_sha` to `git rev-parse HEAD`, the checkout's commit at collect time, instead of the commit the raw file's own run recorded (`metadata.git.commit`). For a sweep collected right after it ran, the two agree, so nothing looked wrong. The tracked record, converted again at a later commit, was stamped with a commit that has the path index. The wire-form gate then resolved "path index on by ancestry, but not recorded" and refused it, which was correct given what it was told.

It stayed hidden because `regenerate.py --check` reads the committed results and never reruns collect. The published results also carried a commit the raw didn't: the record was first collected on its branch, so all of it said `b8e798b`, while 13 of the 16 raw files had run at `d2c647b` or `c0118d6`.

## Fix

`collect.py` takes the commit from the raw metadata and refuses a raw file that has none. The tracked results were regenerated from the raw record: their commits are now the recorded ones (all three resolve to path index and field merge off), and `test_collect.py` checks that a collect over the tracked raw reproduces the tracked results byte for byte, at whatever commit it runs.

## Prevention

- **Provenance comes from the run's record, never from the environment of the converter.** A commit, a toolchain, a host or a flag read at collect time describes the collect, not the run. Every other topic's collect already read `run.json`'s or the raw metadata's commit.
- **If a topic tracks raw inputs, test that collecting them is a no-op on the tracked outputs.** `--check` alone proves the README matches the results, not that the results match the raw.
