---
module: SwiftStateTreeTransport
date: 2026-11-22
problem_type: testing_practice
component: test-probes
symptoms:
  - "a test passes in `swift test` and fails in `swift test -c release`"
  - "a `...ForTesting` probe returns false, nil or at once in a release build"
  - "`swift build -c release` fails: module 'SwiftStateTreeTransport' was not compiled for testing"
root_cause: test_asserts_on_a_probe_compiled_out_of_release
resolution_type: design_rule
severity: low
tags:
  - testing
  - release-build
  - debug-only
  - probes
  - testable-import
related:
  - "#748"
  - "#750"
---

# A test that reads a DEBUG-only probe fails in a release test run

## Problem

Four Transport tests passed in debug and failed, deterministically, in `swift test -c release`. Each read a probe that records only in DEBUG builds: `joinFlippedForTesting` and `initialSyncCommittedForTesting` return `false` outside `#if DEBUG`, and `waitForInboundDrainForTesting` returns at once. CI's release job runs only the turn core's tests, so nothing showed there.

Separately, `swift build -c release` of the whole package failed: the test-support target (`Tests/SwiftStateTreeTestSupport`, a plain `.target`) did `@testable import SwiftStateTreeTransport`, and a plain release build compiles that module without `-enable-testing`. `swift test -c release` enables testing, so it built.

## Root cause

A DEBUG-only probe is a deliberate choice: release builds keep no per-join keys, and the drain-task map is never pruned. The tests that read them carried no gate, so in release they asserted on a probe that can't answer. Where the probe is a wait (`waitForInboundDrainForTesting`), it is the test's synchronisation: in release the test races, not just loses an assertion.

The `@testable import` was needed only for three internal test hooks of `WebSocketTransport`.

## Fix

In #750 (for #748):

- The four tests gate on `.enabled(if: isDebugBuild, …)`. `isDebugBuild` is a package constant in the test support, so a release run skips them by name. The whole test is gated, not single expectations, because a wait probe is the synchronisation the rest of the test relies on.
- `setDelayedCloseForTesting`, `DelayedClose` and `DelayedCloseStage` are `package`, and the test support imports `SwiftStateTreeTransport` without `@testable`.

## Prevention

- A test that reads a probe whose body is under `#if DEBUG` (it returns a constant or at once outside it) carries `.enabled(if: isDebugBuild, …)`. Check by running the touched suites with `swift test -c release --filter …` once.
- A probe that must work in release, because the test is about release behaviour, records in every build behind an off-by-default flag and has a bound on what it keeps.
- A non-test target never uses `@testable import`. Give the hooks it needs `package` access instead, so `swift build -c release` of the whole package keeps building.
