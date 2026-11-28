---
title: "swift test exits 0 when it ran no tests: check the closing lines, not the exit status"
module: CI
date: 2026-11-28
problem_type: testing_practice
component: test-verification
symptoms:
  - "Test run with 0 tests in 0 suites passed after 0.001 seconds."
  - "warning: No matching test cases were run"
  - "a release swift test on Windows exits 0 in seconds"
root_cause: exit_status_counted_as_verification
resolution_type: code_fix
severity: medium
tags:
  - ci
  - testing
  - swift-testing
  - windows
related:
  - "#975"
  - "2026-11-10-a-skipped-test-class-reads-as-passing"
  - "2026-11-24-a-swift-testing-summary-hides-xctest-failures"
---

**Problem.** On Windows, with Swift 6.4.3, `swift test -c release` built and exited 0, but six of seven test bundles printed `Test run with 0 tests in 0 suites passed` (#975). With CI's filter it printed only `warning: No matching test cases were run`, and still exited 0. A minimal package reproduced it, so the cause is in the toolchain. A CI step that ran this would have been green while it verified nothing.

**Root cause.** The steps judged a run by `swift test`'s exit status. Swift Testing reports a bundle with no discovered tests, and SwiftPM reports a filter that matched nothing, as a passing run.

**Fix.** `scripts/check-test-run.sh` reads each test step's log. It fails the step on `No matching test cases were run`, on a Swift Testing closing line `Test run with 0 tests`, or when the log has no closing line at all. It removes carriage returns and NUL bytes first, and matches in the C locale, so a Windows or UTF-16 log is read whole. Every `swift test` step in the Linux, macOS, Windows and examples jobs runs it. Its self-test, in the build job, holds a zero-test, a no-match and an empty log, each also in CRLF and UTF-16. On Linux and macOS a bundle without a match for the step's filter prints no Swift Testing block, so a zero-test block never appears in a green run.

**Prevention.**
- A test step proves what ran by its closing lines: a count above zero for each bundle it expects. An exit status of 0 only says nothing failed.
- When a step's filter narrows the run, check that the filter matched. A renamed suite turns the filter into a no-op that passes.
- A check that reads CI logs is fed a Windows log in its self-test. Line ends and encodings differ there, and a pattern that misses a line passes the step.
