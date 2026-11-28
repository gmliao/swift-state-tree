---
title: "An in-process depth test sized from Linux or release overflows the Mac's debug pool"
module: SwiftStateTree
date: 2026-11-21
problem_type: testing_practice
component: state-conversion-tests
symptoms:
  - "swift test exits with signal 10 (SIGBUS) on macOS while a depth or recursion test runs"
  - "an in-process test at a nesting limit passes on Linux and kills the test process on the Mac"
  - "a crash-reporter dialog appears on the Mac during swift test"
root_cause: in_process_recursion_sized_above_the_darwin_debug_pool_stack
resolution_type: design_rule
severity: medium
tags:
  - testing
  - stack-overflow
  - recursion
  - nesting
  - cooperative-pool
  - debug-build
  - exit-test
related:
  - "#936"
  - "#716"
  - "#735"
---

## Problem

#735 added the nesting budget (`NestingBudget`), and with it an in-process test at the provisional hop limit. That limit was 64, a number sized with Linux and release stacks in mind. On macOS, in a debug build, the test process died with SIGBUS before the budget could refuse the value: 65 unwraps of a nested `Optional<Any>` through `SnapshotValue.make` overflowed the stack. The same test with 33 containers passed.

## Root cause

Swift Testing runs tests on the cooperative pool. On Darwin a pool thread has 524 KiB of stack, and debug frames are large. The S0 measurement (#716, Linux, Swift 6.2.4) shows how far apart the stacks are:

- debug `make` over nested nodes overflows at 34 levels on a 524 KiB thread, and at 512 on an 8 MiB one;
- release reaches 384 levels at 524 KiB.

A depth that is safe on Linux's 8 MiB pool, or in release, can be 15× past what the Darwin debug pool holds. A recursion step that adds no container can also cost more than one that does: casting a nested `Optional<Any>` unwraps the rest of the chain again at every level.

A crash in the test process is worse than a failed test. It ends the whole test run, and on the Mac it raises a crash-reporter dialog.

## Fix

- The hop test uses an explicit small budget (`NestingBudget(containers:hops:)` with 4 hops), so it never recurses deep, and still pins the guard.
- The provisional `stateMaxHops` went from 64 to 32, the smallest value the "one hop per level for `Optional<Node>`" rule allows.
- A follow-up S0 stage measures the wrapper-only shapes on the host.

## Prevention

- **Size every in-process recursion test from the Darwin debug row**: 524 KiB, debug, the worst stage of the path. Linux or release numbers are no guide. When a test only needs to show a guard works, give it a small explicit limit instead of the production one.
- **Keep a case that would overflow if its guard regressed in a child process** (`#expect(processExitsWith:)`), and keep the value it would overflow on far past the limit, so the guard refuses it early. Run the mutant that removes the guard on the Linux host only: on the Mac it crashes on purpose and raises a dialog.
- **Keep the deep value alive until the child exits**, with `withExtendedLifetime(deep) { … exit(0) }`. Its release recurses once per level, and a release build may release a value after its last use, before a later `exit`. A debug build keeps it to the end of its scope, so the debug run passes. #716 S1a-2a's node-chain exit test died with SIGBUS in release only, until its value was kept alive this way.
- **Measure stack-bound limits before choosing them**, on the smallest stack the path runs on (`Notes/solutions/2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md`). A placeholder that has no measurement behind it should sit at the lowest value its own rules allow.

**Correction (#936).** This entry first quoted the pool thread's stack as 544 KiB, the size of its VM region as a crash report names it. `pthread_get_stacksize_np` reports 524 KiB (536,576 bytes) down to the guard page. A VM-region query on a pool thread in #936 shows the 544 KiB region also holding 20 KiB above the stack's top. The measurements here were taken on that thread and stand; only the figure changed.
