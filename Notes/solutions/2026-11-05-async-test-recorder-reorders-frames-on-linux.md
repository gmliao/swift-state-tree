---
module: tests, Examples
date: 2026-11-05
problem_type: testing_practice
component: test-transports
symptoms:
  - "Order-asserting tests pass on the Mac and fail on the Linux CI runners"
  - "A recorded frame is missing when the test reads the recording, or frames appear out of send order"
  - "Code under Examples/ compiles on the Mac and breaks every Linux job that builds it"
root_cause: unstructured_task_per_recorded_frame_and_platform_api_differences
resolution_type: established_pattern
severity: medium
tags:
  - testing
  - linux
  - ordering
  - unstructured-task
  - cross-platform
related:
  - "#139"
---

# Test recorders that log in a `Task` per frame reorder on Linux

## Problem

#139's `Swift Build & Test` jobs (Linux, `swift:6.2.4-noble`; both the in-turn sync on and off builds) failed on three heads, `cb72683a`, `9bdec70c` and `8b6decd7`, while the Mac passed. The joining-admission fixture recorded frames through `RecordingTransport`'s `onSend` callback, which `send` runs in an unstructured `Task { await onSend(message, target) }` per frame. On the Linux runners' multi-threaded executor, frames were recorded out of order, or not yet when the test read them.

A related trap, same lesson: `6c773709` added `ProcessMemory` to EncodingBenchmark, which compiled on the Mac but not on Linux, because Glibc imports `RUSAGE_SELF` as an enum case rather than an `Int32`. It broke every job that builds GameDemo until `261ff1cb`.

## Root cause

An unstructured `Task` per event gives no order between events and no guarantee the event is recorded before the next line of the test runs. The Mac's scheduling hides it; Linux's doesn't. Platform modules (Darwin against Glibc) import some C constants with different types.

## Fix

In #139 (squashed into `8f72c4b0`; branch commit `fc2261c9`): the fixture's transport records each frame synchronously in `send` and `sendBatch` (`TransportAdapterJoiningAdmissionTests.swift`). No assertion changed. `261ff1cb` passes the enum's raw value on Glibc.

## Prevention

- In order-asserting tests, record synchronously inside the transport's `send` / `sendBatch`. Never record through an async callback or a `Task`.
- Watch the PR's own Linux CI before calling a change green; a Mac-only pass isn't evidence for ordering tests.
- Build platform-specific code (anything touching `getrusage`, `/proc`, Glibc or Darwin types) on Linux, in the pinned `swift:6.2.4-noble` image, before pushing.
