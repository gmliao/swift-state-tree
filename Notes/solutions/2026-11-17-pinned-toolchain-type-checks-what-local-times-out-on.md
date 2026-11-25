---
title: "A test-argument literal the pinned toolchain type-checks and a newer one times out on"
module: Tests, toolchain
date: 2026-11-17
problem_type: build_failure
component: swift-testing-arguments
symptoms:
  - "the test target builds on the pinned CI toolchain and fails to build on a newer local one"
  - "macro expansion @Test:12:10: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions"
root_cause: newer_toolchain_type_checker_times_out_on_an_untyped_test_argument_literal
resolution_type: established_pattern
severity: medium
tags:
  - toolchain
  - swift-testing
  - type-checking
  - ci
related:
  - "#571"
  - "#556"
---

# A test-argument literal the pinned toolchain type-checks and a newer one times out on

## Problem

`MergePatchesTests.swift` (#556) passed the cases of a parameterized test as an inline literal in `@Test(…, arguments: [...])`: tuples of `[(String, Int)]` arrays, some of them empty. CI on the pinned toolchain (Swift 6.2.4, Linux) built and passed it. On macOS with Swift 6.4.2 the whole test target failed to build, so no local test run worked:

```
macro expansion @Test:12:10: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
```

It failed the same way twice, with and without load on the machine.

## Root cause

Inside the `@Test` macro's expansion, the arguments literal has no contextual type. The type checker has to infer the element type from tuples whose empty arrays carry no element type of their own, and on 6.4.2 that search ran past its time limit. CI only runs the pinned toolchain, so it can't catch this. It is the mirror of [a concurrency diagnostic the local 6.3 accepts and the pinned 6.2.4 rejects](2026-11-08-local-toolchain-accepts-what-pinned-rejects.md).

## Fix

Give the literal a type outside the macro: `static let mergeCases: [([(String, Int)], [(String, Int)])] = [...]`, then `@Test(…, arguments: mergeCases)`. The cases and assertions don't change (#571).

## Prevention

- Put a parameterized test's cases in a typed `static let` whenever they are more than flat scalars: tuples, nested arrays, or empty collections.
- A local build failure in a test file that CI builds is not a reason to doubt your change. Check whether the failing file is identical on `main` before debugging your own diff.
- With a test target that doesn't build, `swift test --skip-build` runs the last binary that did. Its results describe other sources, so discard them.
