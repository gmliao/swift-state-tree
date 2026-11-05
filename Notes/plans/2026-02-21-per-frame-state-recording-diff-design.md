# Per-Frame State Recording & Reevaluation Diff Design

> Design for debugging reevaluation position/state mismatches by recording full state per frame and comparing with computed state.

## Overview

When reevaluation produces a different state hash than the live recording, we currently have no way to identify which field or value diverged. This design adds optional per-frame state snapshot recording and integrates diff comparison into ReevaluationRunner.

**Scope:** Debug-only feature, enabled via environment variable. File size grows only when enabled.

## Requirements Summary

| Item | Choice |
|------|--------|
| When to record | Debug only: `ENABLE_STATE_SNAPSHOT_RECORDING=true` |
| Storage format | Separate JSONL file: `{recordPath}-state.jsonl` |
| Comparison | Integrated into ReevaluationRunner: `--diff-with <path>` |

## Architecture

```
Live (ENABLE_STATE_SNAPSHOT_RECORDING=true)
  → record.json (unchanged)
  → record-state.jsonl (one line per tick)

ReevaluationRunner --record record.json [--diff-with record-state.jsonl]
  → Run reevaluation
  → If --diff-with: load recorded-state.jsonl, compare with computed state per tick
  → On hash mismatch or diff differences: output to stderr
```

## Section 1: Recording — Per-Frame State to JSONL

**Trigger:** Environment variable `ENABLE_STATE_SNAPSHOT_RECORDING=true` (or `REEVALUATION_STATE_SNAPSHOT_RECORDING`), and `enableLiveStateHashRecording` must already be on.

**When:** In `LandKeeper` tick completion, after `setStateHash`, capture broadcast `StateSnapshot` (same source as hash). Call `ReevaluationRecorder.recordStateSnapshot(tickId:stateSnapshot:)` to buffer.

**Write:** In `ReevaluationRecordSaver.save()`, if state snapshots were recorded, write `{recordPath}-state.jsonl`. Each line: `{"tickId":N,"stateSnapshot":{...}}` (align with `ReevaluationJsonlExporter.TickLine` structure).

**Naming:** Main file `hero-defense-2026-02-22T03-06-34Z-CD3C81D9.json` → state file `hero-defense-2026-02-22T03-06-34Z-CD3C81D9-state.jsonl`.

**Implementation locations:**
- `ReevaluationRecorder`: add `recordStateSnapshot`, write state JSONL in `save()`
- `LandKeeper`: in flush flow, check env and call `recordStateSnapshot`
- Use `EnvHelpers` for env parsing

## Section 2: ReevaluationRunner `--diff-with` Integration

**CLI:** `--diff-with <path>` specifies recorded state JSONL. Can be used with `--verify` and `--export-jsonl`.

**Flow:**
1. If `--diff-with` provided, load recorded-state.jsonl in `prepare()` into `[tickId: JSON]` map
2. After each `step()`, get computed state (same source as `actualState` — snapshot JSON)
3. Look up recorded state for that tick; if both exist, run diff
4. On differences: print to stderr, e.g. `[tick 42] DIFF at players.EF198066.position.v.x: recorded=98100, computed=0`

**Implementation:** ReevaluationRunnerImpl (or GameDemo ReevaluationRunner) parses `--diff-with`, runs diff after each `step()`. New `StateSnapshotDiff` utility: recursive JSON comparison, returns list of `(path, recorded, computed)`.

**Relation to hash verification:** `--verify` still does hash comparison. `--diff-with` provides field-level diff when hash mismatches. Both can be used independently or together.

## Section 3: Comparison Logic, Error Handling, Testing

**StateSnapshotDiff:**
- Recursively compare two JSON objects (nested objects and arrays)
- Output: `path`, `recorded`, `computed` per difference
- No floating-point tolerance; fixed-point integers must match exactly

**Error handling:**
- `--diff-with` file not found: print error, exit 1
- Recorded missing a tick: skip diff for that tick (not an error)
- Computed nil (e.g. encode failed): skip tick, log warning

**Testing:**
- Unit test: `StateSnapshotDiff` (identical, single-field diff, nested diff)
- Integration test: record with state → reevaluation with `--diff-with` → verify output format and exit code

## Files to Modify/Create

| File | Change |
|------|--------|
| `Sources/SwiftStateTree/Runtime/ActionRecorder.swift` | ReevaluationRecorder: `recordStateSnapshot`, write state JSONL in save |
| `Sources/SwiftStateTree/Runtime/LandKeeper.swift` | Check env, call `recordStateSnapshot` in tick completion |
| `Sources/SwiftStateTree/Support/EnvHelpers.swift` | Add key for state snapshot recording (if needed) |
| `Sources/SwiftStateTreeReevaluationMonitor/` or `Examples/GameDemo` | ReevaluationRunner: parse `--diff-with`, run diff after step |
| New: `Sources/SwiftStateTree/Support/StateSnapshotDiff.swift` | Recursive JSON diff utility |
| Tests | StateSnapshotDiffTests, integration test |

## Success Criteria

1. With `ENABLE_STATE_SNAPSHOT_RECORDING=true`, live recording produces `*-state.jsonl` alongside main record
2. `ReevaluationRunner --record X.json --diff-with X-state.jsonl` runs and outputs field-level diffs on mismatch
3. Unit and integration tests pass
