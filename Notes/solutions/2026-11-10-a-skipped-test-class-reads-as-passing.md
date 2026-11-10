---
module: deep-research
date: 2026-11-10
problem_type: testing_practice
component: test-verification
symptoms:
  - "A review run reports N OK, M skipped, and CI then fails a test in the skipped class"
  - "A test passes on macOS and fails on Linux with the same code"
  - "A change to an order or a matrix leaves a stale expectation in a platform-gated test class"
root_cause: platform_gated_test_class_counted_as_verified
resolution_type: established_pattern
severity: low
tags:
  - testing
  - linux
  - cross-platform
  - review
  - verification
related:
  - "#462"
---

# A skipped test class reads as passing

## Problem

#462 moved multiroom-load's profiler-overhead pair from the end of `run.sh`'s matrix to right after the preflight. The Plan tests (the dry run) were updated for the new order. One test in the `Driver` class, which runs `run.sh` for real against a fake scalability script, still expected the pair after the suites. Review ran the topic's tests in a macOS clone and got "70 tests OK, 17 skipped". CI's Linux `examples` job then failed that test: `['preflight', 'overhead-unprofiled', 'suite-1-100'] != ['preflight', 'suite-1-100', 'overhead-unprofiled']`.

## Root cause

The whole `Driver` class is `@unittest.skipUnless(sys.platform.startswith("linux"), ...)`: run.sh's real path (`/proc`, `ss`, the pinning shims) runs on Linux only. On macOS every Driver test was among the 17 skipped, so "OK" covered none of them. The change's author couldn't run Linux either: the host's measuring lock was held, and the change was pushed for CI alone. So nobody had run the one class that exercises the changed order end to end.

The order itself was never in question. `run.sh` walks its `$MATRIX` string in order, and `RUNS` only filters it, so the run order is defined and the same on every platform. Only the test's expectation was stale.

## Fix

The test now expects the matrix order, with a comment that `RUNS` filters but doesn't order. The PR says which order the host runs (preflight, the overhead pair, then the suites), and the re-measure brief's steps were checked against it.

## Prevention

- **A skip count is a list of what wasn't verified.** Read "OK" as covering only the classes that ran. When a change touches what a platform-gated class tests, that class has to run, on its platform, before the change is called verified: in the pinned dev container, or by waiting for CI's Linux job.
- When you change an order, a matrix or a name list, grep the tests for every literal list of those names (`grep -n '"preflight"' test_*.py`), skipped classes included, rather than relying on the run you could do.
- In a review report, state the skip count and which classes it hides. "70 OK" and "70 OK, 17 skipped (all of Driver)" call for different conclusions.
