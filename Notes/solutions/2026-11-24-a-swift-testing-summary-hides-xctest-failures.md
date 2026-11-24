---
module: Tests
date: 2026-11-24
problem_type: testing_practice
component: local-verification
symptoms:
  - "every 'Test run with' line is green locally, but CI fails on a test"
  - "Macro expansion did not produce the expected expanded source in PayloadMacroSortingTests, which the local summary didn't show"
root_cause: swift_test_runs_xctest_and_swift_testing_and_a_summary_read_only_swift_testing_lines
resolution_type: design_rule
severity: medium
tags:
  - testing
  - xctest
  - swift-testing
  - verification
  - macros
related:
  - "#790"
---

# A Swift Testing summary hides XCTest failures

## Problem

#790 changed `@Payload`'s expansion. Locally, every `Test run with … passed` line of `swift test` was green, so the change was reported as verified. CI's `build (variants)` job failed. One XCTest case, `PayloadMacroSortingTests.testPayloadSorting`, still expected the old expansion, and it had failed locally too.

## Root cause

`swift test` runs both test frameworks in one process, and each prints its own result lines:

- Swift Testing prints `✔ Test run with N tests in M suites passed` (or `✘ … failed`) and `✘ Test "…"` per failing test.
- XCTest prints `<file>.swift:<line>: error: -[Suite test] : failed - …` per failure, and `Executed N test(s), with M failures` per suite, including many `Executed 0 tests` lines for suites with no XCTest cases.

A summary that greps only `Test run with` reports green while an XCTest case fails. Most of the repository's tests are Swift Testing, but `Tests/SwiftStateTreeMacrosTests/PayloadMacroSortingTests.swift` is XCTest (`assertMacroExpansion`). A macro change that alters an expansion reaches it.

## Fix

The test's expected source gained `@Payload`'s extension (#790, ccae3885).

## Prevention

Every local test summary greps both frameworks' lines, and a red line from either counts as red:

```bash
swift test 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' \
  | grep -E 'Test run with|✘ Test "|\.swift:[0-9]+: error: |Executed [0-9]+ tests?, with [1-9]'
```

The last pattern matches only a suite with failures (`test` is singular for one test). When reporting a run, quote a Swift Testing `Test run with` line and state that no XCTest `error:` line appeared.
