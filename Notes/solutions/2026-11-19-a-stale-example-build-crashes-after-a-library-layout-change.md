---
module: Examples/GameDemo
date: 2026-11-19
problem_type: gotcha
component: local-build
symptoms:
  - "*** Program crashed: Bad pointer dereference at 0x0000000000000051 *** in GameDemo's tests on Linux"
  - "tryCast / swift_dynamicCast in libswiftCore.so at the top of the crashing thread, with the rest of its stack elided"
  - "the root package's suite passes; only the example package's tests crash, at the same tests every run"
root_cause: incremental_build_of_a_dependent_package_kept_objects_compiled_against_an_old_struct_layout
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - build
  - swiftpm
  - incremental
  - examples
  - crash
  - linux
related:
  - "#632"
---

# A stale example build crashes after a library struct changes its layout

## Problem

In #632, a commit added a stored property to a public library struct (`ReevaluationReplayFrame`, in `SwiftStateTreeReevaluationMonitor`). The root package's suite passed in all three modes. Then `cd Examples/GameDemo && swift build && swift test` reused GameDemo's own incremental `.build`. Two tests that step `ConcreteReevaluationRunner` crashed the test process with signal 11, every run. The crash was a bad pointer dereference in `swift_dynamicCast`, and the crashing thread's frames past the cast were elided, even with `SWIFT_BACKTRACE=limit=none`.

## Root cause

An example package depends on the library by path and has its own build directory. Its incremental build didn't recompile every object that relied on the struct's old layout, so code compiled against two layouts ran in one process. That gives the classic memory-corruption symptoms: a cast on a garbage pointer, at a fixed place.

After `swift package clean` in `Examples/GameDemo` and a full rebuild, the same commit passed all 165 tests. The code was fine.

## Fix

Clean the example's build and rebuild it. The library code needed no change.

## Prevention

- **After a change to a library type's stored properties,** a crash (signal 11, a bad pointer in `swift_dynamicCast` or a witness table) that only an example package shows is first a stale build. Before debugging the code, rebuild that package clean: `swift package clean` in its directory.
- **To find which test died:** list the tests that started but never finished (`◇ Test` lines without a matching `✔`/`✘`). Run them alone with `--filter <function name>`; the display name doesn't match.
- **CI** builds each package fresh, so it doesn't see this. A local verification that runs an example's tests on a reused `.build` can report a crash the code doesn't have, or miss one it does. A run whose result goes into a PR rebuilds the example clean when library layouts changed.
