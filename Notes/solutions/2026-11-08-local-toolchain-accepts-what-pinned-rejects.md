---
module: SwiftStateTreeTransport, toolchain
date: 2026-11-08
problem_type: build_failure
component: transport-adapter
symptoms:
  - "A change builds and passes every test on the Mac, and every Linux CI job fails to compile it"
  - "error: sending 'encode' risks causing data races [#SendingRisksDataRace]"
  - "note: 'self'-isolated 'encode' is captured by a actor-isolated closure"
root_cause: newer_local_toolchain_accepts_region_isolation_code_the_pinned_one_rejects
resolution_type: established_pattern
severity: medium
tags:
  - toolchain
  - concurrency
  - region-isolation
  - ci
  - linux
related:
  - "#297"
---

# A concurrency diagnostic the local 6.3 accepts and the pinned 6.2.4 rejects

## Problem

A review fix on #297 (`034c815b`) changed `TransportAdapter.encodeDroppingUnencodablePatches`, an actor method that takes a non-escaping `encode` closure. Its `patches.filter { … }` closure called `encode` and now also touched `self` (`unmappedPathCounter.recordDroppedPatch()`). The Mac (Swift 6.3.x) built it, and root `swift test` passed in both `IN_TURN_SYNC` modes. Every Swift job in CI (`swift:6.2.4-noble`: both builds, `examples` and the E2E jobs) failed to compile it at `612a4c40`:

```
TransportAdapter.swift:4645:13: error: sending 'encode' risks causing data races [#SendingRisksDataRace]
note: 'self'-isolated 'encode' is captured by a actor-isolated closure. actor-isolated uses in closure may race against later actor-isolated uses
```

## Root cause

Region-based isolation checking changed between 6.2 and 6.3. 6.2.4 treats the parameter closure captured by an actor-isolated closure that also uses `self` as sent into that closure, and so as racing the later direct call `encode(kept)`. 6.3 doesn't. The pinned toolchain is the gate (CLAUDE.md, "Pinned toolchain"), so a local pass on a newer toolchain is no evidence for code near isolation boundaries.

## Fix

Replace the closure with a plain `for` loop that appends to `kept`. Then nothing captures `encode`, and the method calls it directly on each iteration. No behavior change (`5f4696d5`). The unfixed method fails the same way in a local `swift:6.2.4-noble` container, and the fixed one builds there.

## Prevention

- Before pushing a core change that touches actor methods, closures over `self`, `sending`/`@Sendable` parameters or `Task`s, build it with the pinned toolchain:
  `docker run --rm -v "$PWD":/src -v sst-scratch:/b -w /src swift:6.2.4-noble swift build -j 1 --target <Module> --scratch-path /b`.
  `-j 1` and a named scratch volume keep a small Docker VM (about 1 GB) from killing the compiler with signal 9, and the volume makes the next build incremental.
- In an actor method, prefer a loop to a closure when the body would capture both a closure parameter and `self`.
- Watch the PR's own CI to the end after every push ([async recorders on Linux](2026-11-05-async-test-recorder-reorders-frames-on-linux.md) is the same lesson for runtime behavior).
