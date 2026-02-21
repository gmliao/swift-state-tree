# Server Event Recording & Verification Design

> **For Claude:** Use superpowers:writing-plans to create implementation plan after design approval.

## Goal

1. **Record server events** in the server's live recording output (JSON record file) to enable verification that reevaluation produces identical server events.
2. **Verify** that the per-frame state hash correctly proves deterministic reevaluation.

## Background

- **Current state**: Live recording captures `stateHash`, `actions`, `clientEvents`, `lifecycleEvents` per tick. Server events (`ctx.emitEvent()`) are **not** recorded.
- **Gap**: State hash matches between live and replay, but we cannot verify that server events are 100% identical. Deterministic state implies deterministic events in theory, but we lack empirical verification.
- **Frame hash**: The per-tick `stateHash` is computed from the full state snapshot (FNV-1a 64-bit). Same hash ⇒ same state. We need to document and verify that this proves reevaluation correctness.

## Design

### 1. Add `serverEvents` to ReevaluationTickFrame

**File**: `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`

- Add `serverEvents: [ReevaluationRecordedServerEvent]` to `ReevaluationTickFrame` (default: `[]` for backward compatibility when decoding old records).
- Update `ReevaluationTickFrame.init` to accept `serverEvents`.
- All `ReevaluationTickFrame` construction sites must pass `serverEvents` (or `[]`).

### 2. Add `recordServerEvents` to ReevaluationRecorder

**File**: `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`

- New method: `recordServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent])`.
- Merges `serverEvents` into the current frame for `tickId`. If frame does not exist, create one (same pattern as `setStateHash`).
- Events must be sorted by `sequence` before recording (caller responsibility; `flushOutputs` already sorts).

### 3. Record Server Events in Live Mode (LandKeeper)

**File**: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`

- In `flushOutputs(forTick:)`, when `mode == .live` and `reevaluationRecorder != nil`:
  - Convert `toFlush` to `[ReevaluationRecordedServerEvent]` (same mapping as reevaluation sink path).
  - Call `await recorder.recordServerEvents(tickId: tickId, events: records)`.
- Order: `flushOutputs` runs after `setStateHash`, so the frame for this tick already exists.

### 4. ReevaluationSource: Optional `getServerEvents`

**File**: `Sources/SwiftStateTree/Runtime/ActionSource.swift`

- Add to `ReevaluationSource` protocol: `func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent]`.
- Default implementation returns `[]` for sources that don't have server events (backward compat).
- `JSONReevaluationSource`: return `framesByTickId[tickId]?.serverEvents ?? []`.

### 5. Verification: Compare Recorded vs Emitted Server Events

**Location**: ReevaluationRunner (Demo + GameDemo) and/or ReevaluationEngine

- When replaying with verification enabled:
  - For each tick, get `recordedServerEvents` from source (if available).
  - Get `emittedServerEvents` from the capturing sink.
  - Compare: same count, same order, same `typeIdentifier`, same `payload` (via `AnyCodable` equality or JSON comparison).
- Report mismatches (tick, expected vs actual).
- Exit with error if any mismatch when `--verify` is used.

### 6. Frame Hash Verification Documentation

- Add a short section to `docs/core/reevaluation.md` (and `.zh-TW.md`):
  - **State hash proves reevaluation**: The per-tick `stateHash` is a deterministic FNV-1a64 hash of the full state snapshot. If live and replay produce the same hash for every tick, the state transition logic is deterministic. Server events are derived from the same handlers and inputs; recording them allows an additional consistency check.
- Optional: Add a unit test that demonstrates: same inputs → same state hash → same server events (when both are recorded).

## Backward Compatibility

- Old record files (without `serverEvents`) decode with `serverEvents: []` via `Codable` default.
- `getServerEvents` returns `[]` when frame has no server events.
- Verification step skips comparison when `recordedServerEvents.isEmpty` (no recorded baseline).

## Success Criteria

1. New records include `serverEvents` per tick when events are emitted.
2. ReevaluationRunner `--verify` compares server events and fails on mismatch.
3. Documentation explains that state hash proves reevaluation; server event comparison is an additional check.
4. All existing tests pass; new tests cover server event recording and verification.
