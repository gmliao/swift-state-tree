---
module: SwiftStateTree, Examples
date: 2026-01-27
problem_type: gotcha
component: release-builds
symptoms:
  - "A crash only in `-c release`, never in debug: SIGABRT in `swift_task_dealloc`, or \"freed pointer was not the last allocation\""
  - "Only under load or with several rooms; a single-room run is fine"
  - "Debug builds and the sanitizers pass"
root_cause: runtime_bug_and_c_varargs_abi_mismatch_exposed_by_optimization
resolution_type: established_pattern
severity: high
tags:
  - release
  - crash
  - task-sleep
  - string-format
  - macos
---

# Release-only crashes: `Task.sleep(for:)` and `%s` with a Swift `String`

## Problem

Two different causes, same symptom: a crash that only shows up in release builds under load.

- **`Task.sleep(for: Duration)`** can crash in macOS release builds under load (SIGABRT in `swift_task_dealloc`), a Swift concurrency runtime bug.
- **`String(format: "%s", swiftString)`**: `%s` expects a C string pointer. In the multi-room release benchmark this produced "freed pointer was not the last allocation" for every encoder ([`Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md`](../../Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md)). Debug builds happened to tolerate the mismatch.

## Fix

- `safeTaskSleep(for:)` in `Sources/SwiftStateTree/Support/SafeTaskSleep.swift` converts the `Duration` to nanoseconds and calls `Task.sleep(nanoseconds:)`.
- No C varargs formatting with Swift objects: string interpolation, or `Logger` with metadata. Hex encoding has typed helpers (`paddedLowerHex` in `DeterministicHash.swift`, `HexEncoding` in the transport), added in `4ec744a8`.

## Prevention

- Library code uses `safeTaskSleep(for:)`, never `Task.sleep(for:)` (`CLAUDE.md` § Concurrency).
- Never `%s` with `String` / `Substring` in `String(format:)`, `NSString(format:)` or `NSLog` (`AGENTS.md` § Safe String Formatting).
- Run concurrency-heavy changes and benchmarks with `swift build -c release` at least once; release builds expose bugs debug builds hide (`CLAUDE.md` § Common Commands).
