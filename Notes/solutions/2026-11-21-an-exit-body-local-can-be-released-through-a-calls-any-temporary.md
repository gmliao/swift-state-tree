---
title: "An exit body's local can be moved into a call's `Any` temporary and released there"
module: SwiftStateTree
date: 2026-11-21
problem_type: gotcha
component: exit-tests
symptoms:
  - "an exit test passes in debug and on the Mac, and fails in a Linux release build with \"Expectation failed: .success\""
  - "the child dies after the refusal it was testing for, while releasing a deep structure"
  - "`withExtendedLifetime(x) { ...; exit(0) }` doesn't keep `x` alive through a call that takes it as `Any`"
root_cause: a_value_moved_into_an_any_temporary_is_released_with_the_temporary_even_when_the_body_ends_in_exit
resolution_type: established_pattern
severity: medium
tags:
  - exit-tests
  - lifetime
  - release-build
  - stack-overflow
  - nesting-budget
related:
  - "#716"
  - "#742"
---

# An exit body's local can be moved into a call's `Any` temporary and released there

## Problem

#742 split one exit test into three, one per member (`make`, `makeFull`, `snapshotForSync`). Each child builds a 100 000-level node chain, converts it, expects the nesting refusal, and calls `exit(0)`. The chain's release recurses once per level, so the chain must never be released: the body wraps it in `withExtendedLifetime` and ends in `exit`.

In a Linux release build (Swift 6.2.4) the `make` and `makeFull` children failed, every run. The `snapshotForSync` child passed, debug passed, and the Mac release build passed.

## Cause

The chain's release is the failure: with a global holding one more reference until `exit`, all 26 release tests and all 28 debug tests pass on the same Linux toolchain, and the mutants are still caught. The mechanism below is inferred from which members failed; it was not observed.

- On a path that ends in a `Never` call such as `exit`, the compiler emits no destroy for the function's locals. That is what keeps an owned local alive, not `withExtendedLifetime`, whose end is unreachable there.
- A call that takes the value as `Any` gets a temporary existential, destroyed right after the call, on the throw path too.
- When the call is the local's last use, the optimizer may move the local into that temporary instead of copying it. Destroying the temporary is then the last release, and the chain's recursive release overflows the stack.
- `snapshotForSync` borrows the value as `self`, with no temporary, so it never released anything.

The single test before the split had the same body shape, but its closures captured the chain, so the temporary held a copy and the closure array kept the last reference until `exit`.

## Fix

A file-scope global holds the chain until the process exits (`deepChainKeptAlive` in `GeneratedNestingBudgetTests.swift`), so whatever the optimizer does with the local, a reference outlives the call.

## Diagnosing an exit test

`#expect(processExitsWith:)` returns `nil` when the expectation fails, and the runner prints only "Expectation failed: .success". So a print of the returned result can't tell a signal from an exit code in a failing child. To see the status, run the diagnostic with the condition you suspect (`.signal(SIGSEGV)`, or `.exitCode(2)`): when it matches, the expectation passes and the result carries `exitStatus` and the child's output.

## Rule

In an exit test that must not release a value, keep a reference in a global (or a container that lives until `exit`), not only in a local, when the value is passed as `Any` or moved into another owner. Run the exit test in release on Linux before trusting it: neither debug nor the Mac release build showed this.
