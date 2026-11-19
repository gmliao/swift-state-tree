---
module: CI
date: 2026-11-19
problem_type: gotcha
component: ci-apt-install
symptoms:
  - "a CI job shows cancelled, not failure, with no newer run that could have cancelled it"
  - "a step that retries on error sits for the job's whole timeout-minutes and logs nothing"
  - "Install curl ran from 12:05 to 12:35 and every later step was skipped"
root_cause: retry_loop_only_reacts_to_an_exit
resolution_type: code_fix
severity: medium
tags:
  - ci
  - apt
  - retry
  - timeout
  - hang
  - shell
related:
  - "#659"
  - "#453"
---

# A retry loop catches failures, not hangs

## Problem

`scripts/ci-apt-install.sh` (#453) retried `apt-get update && apt-get install` up to five times, with growing waits, for mirror errors. On an E2E run (#659) its `Install curl` step ran for 30 minutes and the job came out `cancelled`. The run's other jobs passed, and no newer run had superseded it.

## Root cause

The loop acts on an exit code. A download that stalls without failing never exits, so the loop never reaches its next attempt. `Acquire::Retries` retries a failed download, not a stalled one. The step had no limit of its own, so the job's `timeout-minutes` was the only bound. GitHub ends a job at its limit as `cancelled`, not `failure`, which hides the step that hung and the cause.

## Fix

- Each `apt-get` call runs under `timeout --kill-after=10 <seconds>`, so a stall becomes a failure the loop retries.
- After a killed install, a retry first runs `dpkg --configure -a`.
- The helper's header states its worst case (attempts × bounds + waits). Each step that calls it sets `timeout-minutes` above that, so a hang fails that step by name.
- `scripts/test-ci-apt-install.sh` runs the helper against stub commands that fail or hang, with the bounds shortened through environment variables. The helper from before the fix stays stuck under the test's hang case.

## Prevention

- **Bound every attempt.** A retry loop around a network call bounds each attempt (`timeout`), not only the whole: an attempt that never returns defeats any number of retries.
- **Bound the step.** Give the step its own `timeout-minutes`, above the helper's stated worst case. The job's limit names nothing and reports `cancelled`.
- **Test both shapes.** A test of the helper covers a failure and a hang, with a stub that stalls past the bound.
