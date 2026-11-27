---
title: "A test file that uses #if DEBUG types needs the same guard: .enabled(if:) gates the run, not the compile"
module: testing
date: 2026-11-26
problem_type: build_error
component: test-targets
symptoms:
  - "a test file compiles in `swift test` (debug) and fails to compile in `swift test -c release`"
  - "an env-gated or disabled test still breaks a release CI job"
root_cause: a_new_test_file_used_types_declared_only_under_if_debug_without_the_guard
resolution_type: established_pattern
severity: medium
tags:
  - swift-testing
  - release-build
  - ci
related:
  - "#924"
---

# A test file that uses #if DEBUG types needs the same guard: .enabled(if:) gates the run, not the compile

## Problem

#924 added `DiffBackPressureProbeTests`, gated with `.enabled(if: DIFF_BACKPRESSURE_PROBE=1)`. It uses `DiffRun`, `DiffScenario` and `diffScenarios`, which the differential harness declares only under `#if DEBUG`. The Mac's debug `swift test` and the pre-push checks passed, but CI's release jobs (`swift test -c release`) build every test target, and the file wouldn't compile there. Review caught it before CI ran.

## Root cause

`.enabled(if:)`, `.disabled` and an environment gate decide whether a test *runs*. The file is still compiled in every configuration. A new file next to `#if DEBUG` siblings doesn't inherit their guard.

## Prevention

- When a new test file uses a type, function or global from a sibling file, check that sibling's `#if` guard and wrap the new file in the same one.
- A gate for "don't run this by default" is `.enabled(if:)`; a guard for "this can't build here" is `#if`. A file that needs the second needs it even when it has the first.
- A release-only build failure isn't caught by a debug Mac run or by pre-push. Build the test target in release (`swift build -c release --build-tests`) in CI or the cloud, not on the Mac slot.
