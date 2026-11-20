---
module: SwiftStateTreeMacros
date: 2026-11-20
problem_type: gotcha
component: build
symptoms:
  - "a mutant in a macro's generated code survives every test"
  - "after editing only a macro implementation, the tests behave as before the edit"
  - "swift build after a macro edit finishes in seconds and recompiles no client module"
root_cause: an_incremental_build_does_not_reexpand_clients_when_only_the_macro_changed
resolution_type: tool_fix_and_method_rule
severity: medium
tags:
  - macros
  - mutants
  - incremental-build
  - toolchain
  - testing
related:
  - "#699"
  - "#669"
---

# A macro-only change doesn't rebuild the clients that expand it

## Problem

To prove that `SyncEngineLargeStateDiffTests` checks the dirty sets, two mutants changed the code `@StateNodeBuilder` generates for `getDirtyFields()` (`StateNodeBuilderMacro.generateGetDirtyFieldsMethod`): `if true` (every field dirty) and `if false` (no field dirty). Built with `swift build --build-tests` and run, both mutants survived. Once the test module was rebuilt, both were killed.

## Root cause

With Swift 6.2.4 on Linux, an incremental `swift build --build-tests` rebuilt the macro target, but not the client modules whose sources it expands (here `SwiftStateTreeTests`, where `BenchmarkStateRootNode` is declared). The test binary kept the previous expansion. The build finished in about 11 s and compiled none of `SwiftStateTreeTests`.

## Fix

Touch a source file of each client module that expands the changed macro before building. For the mutants above, `touch Tests/SwiftStateTreeTests/SyncEngineLargeStateDiffTests.swift`: the build then compiled `SwiftStateTreeTests` again (about 70 s) and both mutants failed four and three tests.

## Prevention

- A mutant in a macro implementation proves nothing until the build shows its clients compiling again: look for `Compiling <client module>` in the build output, or touch a client source first.
- The same holds for a real macro change verified with an incremental build: a clean build, or CI, is the check.
- A mutant that survives is a finding about the tests only once the mutant is known to be in the binary.
