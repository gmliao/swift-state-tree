---
module: SwiftStateTreeMacros
date: 2026-11-09
problem_type: testing_practice
component: macro-tests
symptoms:
  - "macro expansion test passes although the expected source is wrong"
  - "assertMacroExpansion mismatch prints nothing under swift test"
  - "test still passes after changing the macro's output"
root_cause: xctest_assertion_called_from_swift_testing_test
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - macros
  - swift-testing
  - xctest
  - swift-syntax
related:
  - "#187"
  - "#248"
  - "#404"
---

# An XCTest assertion is silent inside a Swift Testing test

## Problem

The macro tests are Swift Testing tests (`@Test`), but they called `assertMacroExpansion` from `SwiftSyntaxMacrosTestSupport`, which reports a mismatch through `XCTFail`. When it's called from a Swift Testing test, no XCTest case is running, and the failure is lost. 11 of the 15 expansion tests had wrong expectations and passed anyway:
- 8 expected sources had drifted as the macros gained members over a year;
- 1 diagnostic column was wrong from the day it was written;
- 2 tests receive a duplicate diagnostic, a real bug (#404).

## Root cause

XCTest assertions record into the current `XCTestCase`. Swift Testing has its own issue recording (`Issue.record`, `#expect`). A helper that only knows XCTest does nothing visible under Swift Testing, so the test passes whatever the macro produces.

## Fix

`Tests/SwiftStateTreeMacrosTests/MacroExpansionExpectation.swift` defines `expectMacroExpansion`. It calls the framework-neutral `assertMacroExpansion(..., failureHandler:)` from `SwiftSyntaxMacrosGenericTestSupport` (swift-syntax 600+), and its failure handler records each failure with `Issue.record` at the caller's source location. Every Swift Testing macro test uses it. The one XCTest suite (`PayloadMacroSortingTests`) keeps the XCTest form.

Each corrected expectation was traced to the macro commit that changed the output before it was accepted (#248). A difference that can't be traced to a deliberate change is a bug, not a new expectation.

## Prevention

- In a Swift Testing test, never call a helper that asserts through XCTest (`XCTAssert*`, `XCTFail`, or `SwiftSyntaxMacrosTestSupport.assertMacroExpansion`). Use `#expect`, `Issue.record`, or a generic helper with a failure handler.
- A new assertion helper has to fail once before it's trusted: change one character of an expected value and see the test go red.
- Known bugs that a strict assertion exposes go in `withKnownIssue` with the issue number. The wrapper fails once the bug is fixed, so it can't outlive the bug.
