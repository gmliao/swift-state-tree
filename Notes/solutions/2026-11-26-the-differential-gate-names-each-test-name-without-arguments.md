---
title: "The differential gate names each test `name()`: no parameterized tests, and each @Test on one line, in its suites"
module: testing
date: 2026-11-26
problem_type: ci_failure
component: differential-harness
symptoms:
  - "differential-gate: <file> has N @Test line(s) but N-1 test name(s) found: put each @Test on the line before its func"
  - "differential-gate: these tests didn't pass in the results: ...<name>()"
root_cause: a_parameterized_test_whose_attribute_spanned_lines_in_a_gated_suite
resolution_type: established_pattern
severity: low
tags:
  - swift-testing
  - ci
  - differential-harness
related:
  - "#924"
---

# The differential gate names each test `name()`: no parameterized tests, and each @Test on one line, in its suites

## Problem

#924 added a parameterized self-check to `DiffSelfCheckTests.swift`, written as `@Test(\n "…",\n arguments: […]\n)`. The suites passed in CI, but the "differential harness (goldens)" job failed in `scripts/differential-gate.sh`: the file had 13 `@Test` lines and 12 test names.

## Root cause

The gate proves that every declared test passed by reading the suites' files. It finds each name with `@Test\b[^\n]*\n\s*func\s+(\w+)\(`: the attribute must be on one line, directly above its `func`. It then looks for `<name>()` in Swift Testing's xunit results. A parameterized test is recorded as `name(land:)`, so even on one line it would be reported as missing.

## Prevention

- In `DifferentialHarnessTests.swift` and `DiffSelfCheckTests.swift`, keep each `@Test(...)` on the line before its `func`, and give no test arguments. For several cases, write one test per case over a shared private helper.
- Before pushing a change to those files, run the gate's test filter with `--xunit-output`, then the gate's Python check on the result. The whole script needs the pinned image.
