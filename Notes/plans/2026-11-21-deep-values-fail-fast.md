# Deep or cyclic values fail fast instead of overflowing the stack (#716)

Rev 1, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 5dff1aea.

## 1. Problem

A value that nests too deep, or a cycle through a class, overflows the thread's stack in a recursive stage before any bound refuses it. The process dies (SIGBUS) and every land on it goes with it. The rule this plan applies (`Notes/solutions/2026-11-18-a-parsers-depth-limit-isnt-the-pipelines.md`): every recursive stage needs a bound it can walk on the smallest stack it runs on (Darwin's cooperative pool, 544 KiB), and a value past the bound fails the land, never the process.

Measured in #697 (issue comment on #716): a chain of nested `@StateNodeBuilder` nodes, 2 containers per level, overflows in `SnapshotValue.make` at 28 levels in a debug build on macOS (26 syncs). In release, 28 syncs and 34 reaches the packer (`syncEncode`). The packer's 64 (#697) is never reached by nested-node state in debug.

## 2. The recursive stages

| # | Stage | Where | Runs on | Recursion | Bound today |
|---|---|---|---|---|---|
| R1 | Client view of state | `SnapshotValue.make(from:for:)`, `broadcastView(of:)`, the macro's `snapshot(for:dirtyFields:)` (`StateNodeBuilderMacro.swift:416`) and its per-field conversion code | keeper (sync phase, first sync of a joiner) | per container, through Mirror and per-node generated code | none |
| R2 | Typed sync diff | `SyncNodeDiffer`, `SyncOptionalNodeDiffer`, `SyncNodeMapDiffer.diffRows` (`SyncTables.swift:779-923`); a new or replaced row converts through R1 | keeper (sync phase) | per nested node | none |
| R3 | Full state for the hash | `SnapshotValue.makeFull`, `fullStateSnapshot()`, `toFullSnapshotValue()` (`@SnapshotConvertible`); callers `ActionRecorder`, `ReevaluationEngine` | keeper (recording) and the reevaluation runner | per container | none |
| R4 | Hand-written `toSnapshotValue()` | the adopter's code | as R1 | the adopter's | none (out of scope, documented) |
| R5 | Payload fallback encode | `MessagePackDirectEncoder` (`encode(to:)` of a payload's `Codable` fields), `JSONEncoder` on JSON encodings (`TransportCodec.swift:58`) | keeper / adapter | per level of the value, unbounded for a cycle through a class | none |
| R6 | Wire | the packer and unpackers | adapter | per container | 64 (#697), 32 for client frames (#595), record codec 128 |

S0 (below) checks two more before the design is final: how a land's save encodes state, and the client SDK's own patch apply. Neither is assumed safe.

## 3. Design

### 3.1 One deterministic limit, counted in containers

A synced value may nest at most `PayloadNesting.stateMaxDepth` containers (objects and arrays of the converted value, counted as the unpacker counts them). R1, R2 and R3 count the same thing and refuse the same values, so the live sync, the recorder's state hash and a replay (#612) refuse at the same state, on every platform and build. The limit is a count, not a check of the remaining stack: a stack check would refuse at different depths on Linux, on macOS and per build, and a replay could then disagree with its live run.

Its value: at most `serverFrameMaxDepth` minus the deepest state frame's own levels, so a state that converts always packs (the packer's 64 stays as the last stage, #697). And low enough that R1–R3 can walk it on 544 KiB in a debug build, with headroom. Debug overflowed at 56 containers (28 node levels), so 64 can't be the value as the code stands. Two ways out, measured in S0 and decided by the maintainer:
- (a) Shrink the stack per level first. `SnapshotValue.make` is one large function: every `case let x as T` cast and the Mirror paths share one frame (`___chkstk_darwin` sits at its top in the backtrace). A thin dispatcher with the slow paths moved out (`@inline(never)`) may cut the bytes per level several times. If debug then walks 64 with about 2× headroom, the limit is the wire's.
- (b) A lower state limit (for example 32 containers, 16 node levels), as #595 did for client frames. Simpler, but it restricts what a game can model, which #595 avoided for server frames on purpose.

The recommendation is (a), then whichever limit S0's measurements support, with (b) as the fallback if (a) doesn't reach 2× headroom.

### 3.2 How the count is carried

The generated `snapshot(for:dirtyFields:)` is the protocol requirement R1 recurses through, so a depth parameter would change the macro's output and `StateNodeProtocol`. Two options:
- (i) A depth parameter on new internal entry points (`make(from:for:depth:)`, a defaulted `snapshot(for:dirtyFields:depth:)` that the macro generates and the old signature forwards to). Exact and free at runtime; a macro and protocol change (listed under Public API, source compatible through the default).
- (ii) A per-thread counter (`pthread_getspecific`), incremented on entry to each container conversion and decremented on exit. No signature change, but a lookup per container on the hot path, and a counter that a throw must unwind correctly (`defer`).

Recommendation: (i). The conversion is synchronous, so a parameter is the honest carrier; (ii) hides state in the thread. R2 carries the depth in `SyncDiffPosition`, which every differ already passes down. R3 gets the same parameter as R1.

### 3.3 How a too-deep state fails

R1 and R2 throw `SyncError.nestingTooDeep(limit:)` (new case). In the sync phase that is a conversion failure: `ExtractionDrops` → `noteExtractionDrops` (`SyncPhaseTypes.swift:171`) ends the land with `LandFailure.Kind.syncConversion`, the field named. That is the existing kind for "a synced value didn't convert" (`LandFailure.swift:12`). It is not `syncEncode`, which means a frame didn't encode; question Q2 asks whether the maintainer wants it reported as `syncEncode` instead. S0 checks the other callers before S1 relies on them: a joiner's first sync, the recorder's handling of a throwing `fullStateSnapshot` (R3), and the reevaluation runner's (a hash error there should fail the run). Each must end the land or fail the run, not drop the error.

The limit is checked at conversion, so it is reached before the packer, and the packer's refusal of a state frame (#697) becomes unreachable for converted state; it stays for frames built from other sources.

### 3.4 Cycles and class fields in payloads

- Registration: refuse a class-typed field at every level of an event's, action's or response's declared type, as #464 does for synced state (`SyncValueSemantics`: a metatype check at each level plus a default-instance Mirror descent). One validator shared by both. This is a behavior change (a land with such a payload no longer registers) and goes under Public API with a docs line, en and zh-TW.
- Runtime backstop for what registration can't see (an `AnyCodable`, a field hidden by a hand-written `encode(to:)`): `MessagePackDirectEncoder`'s walk gains a depth count and refuses past `serverFrameMaxDepth`, which also stops a cycle (S0 finds where its recursion enters; it keeps no `codingPath` today). JSON payloads go through `JSONEncoder`, which can't be bounded from outside; for them registration is the guard, and the docs say a hand-written `encode(to:)` that walks a cycle is the adopter's (as for R4).
- The value trees (`SnapshotValue`, `MessagePackValue`) are enums, so they can't hold a cycle; nothing past R5 needs cycle handling.

### 3.5 Tests that can't overflow the runner

- Every over-the-limit value is built iteratively (a reduce, as `PackDepthTests.stateFrameBound` does), so the test itself never recurses.
- Every case that would overflow if its guard regressed runs as an exit test (a child process, as the 100,000-level leaf test in #697 does): a regression fails one test instead of killing the test bundle and hiding the rest.
- In-process cases stay shallow: at the limit and one past it, refused by the count before the recursion is deep.
- Per stage: R1 (`make`, `broadcastView`, a land's sync: `syncConversion` with the field), R2 (a row replaced at depth), R3 (`fullStateSnapshot` and the recorder), R5 (a class field refused at registration; a cycle in an `AnyCodable` refused by the encoder).
- Run on macOS debug and release locally and on Linux in CI; the edge measurement (S0) runs one process per depth.
- Mutants: each guard removed, and each off by one.

### 3.6 Fit with #697 and #612

- #697: the wire limit stays the last check. The state limit is derived from it (3.1), so the two can't disagree; a test pins `stateMaxDepth + deepest state frame overhead ≤ serverFrameMaxDepth`.
- #612 (replay on the turn core, parked until #546): replay runs the same conversion (R1–R3) through the same entry points, so the count refuses at the same input live and in replay. This plan adds no replay-specific path, and #612's rev 5 needs no change beyond a pointer. The record codec's 128 is above the state limit, so a recorded state always decodes.

## 4. Steps

- **S0, measure (slot, no library change):** per stage, the deepest value that converts on macOS debug and release (one process per depth, nested nodes and nested arrays/maps); the bytes per level; the same with a prototype of 3.1 (a) in a scratch branch. Check the save path and the SDK patch apply (§2). Output: a table in this plan and the limit proposal for Q1.
- **S1:** the count through R1–R3 (3.2 (i)), `SyncError.nestingTooDeep`, the failure mapping (3.3), and 3.1 (a) if S0 supports it. Tests per 3.5. EncodingBenchmark A/B on the Mac (the count is on the hot path), host A/B if beyond noise.
- **S2:** payload class refusal at registration and the direct encoder's bound (3.4), with docs.
- **S3:** docs: the state limit in `docs/core/failure-handling.md` and `sync.md` (en and zh-TW), replacing the #697 Limit sentence; the solutions entry updated.

S1 and S2 are independent PRs. Each touches `Sources/`, so each goes through a PR and Review.

## 5. Questions for the maintainer

- Q1: the state limit: the wire's 64 minus the frame's levels, if 3.1 (a) makes debug walk it with about 2× headroom; otherwise a lower limit (b). The plan recommends (a) first.
- Q2: the failure kind for a too-deep state: `syncConversion` (the plan's choice: conversion is where it's found) or `syncEncode`.
- Q3: refusing class-typed payload fields at registration is a behavior change; confirm it, or keep classes and rely on the encoder bound (JSON payloads then stay unguarded).
- Q4: 3.2 (i), a defaulted depth parameter on the generated `snapshot`, against (ii), a per-thread counter.
