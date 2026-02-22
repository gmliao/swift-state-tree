[English](reevaluation.md) | [中文版](reevaluation.zh-TW.md)

# Deterministic Re-evaluation

> SwiftStateTree's Re-evaluation capability allows you to record live game sessions and replay them deterministically for debugging, testing, and analysis.

## Overview

Re-evaluation is the ability to **re-execute state transition logic under fixed world conditions**. Unlike traditional replay (which just plays back recorded data), Re-evaluation actually runs the handlers again with the same inputs.

### Key Concepts

| Concept                  | Description                                                    |
| ------------------------ | -------------------------------------------------------------- |
| **Live Mode**            | Normal execution, records all inputs and resolver outputs      |
| **Reevaluation Mode**    | Replays recorded inputs, skips resolvers, verifies state hash  |
| **Deterministic Output** | Events and sync requests are queued and flushed at end of tick |

## How It Works

### Recording (Live Mode)

In Live mode, `LandKeeper` automatically records:

1. **Actions** - `sequence`, `payload`, `resolverOutputs`, `resolvedAtTick`
2. **Client Events** - `sequence`, `payload`, `resolvedAtTick`
3. **Lifecycle Events** - `OnJoin`, `OnLeave`, `OnInitialize` with resolver outputs
4. **Server Events** - Events emitted via `ctx.emitEvent()`
5. **State Hash** - Optional per-tick hash for verification

```swift
// Recording is automatic in Live mode
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .live,  // Recording enabled
    enableLiveStateHashRecording: true  // Enable per-tick hash
)
```

### Replay (Reevaluation Mode)

In Reevaluation mode, `LandKeeper`:

1. Loads recorded inputs from `ReevaluationSource`
2. Skips resolver execution, uses recorded `resolverOutputs`
3. Executes handlers with same inputs
4. Compares state hash after each tick

```swift
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .reevaluation,
    reevaluationSource: JSONReevaluationSource(filePath: "recording.jsonl")
)

// Step through ticks manually
await keeper.stepTickOnce()
```

## Recording Format

Recordings are saved as JSONL (JSON Lines) format:

```jsonl
{"kind":"metadata","landID":"game:abc123","landType":"game","createdAt":"2024-01-01T00:00:00Z"}
{"kind":"frame","tickId":0,"actions":[],"clientEvents":[],"lifecycleEvents":[{"kind":"initialize",...}]}
{"kind":"frame","tickId":1,"actions":[{"sequence":1,"typeIdentifier":"MoveAction",...}],...}
```

### Data Structures

| Structure                | Fields                                                                                                            |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `RecordedAction`         | `sequence`, `typeIdentifier`, `payload`, `playerID`, `clientID`, `sessionID`, `resolverOutputs`, `resolvedAtTick` |
| `RecordedClientEvent`    | `sequence`, `typeIdentifier`, `payload`, `playerID`, `clientID`, `sessionID`, `resolvedAtTick`                    |
| `RecordedLifecycleEvent` | `kind`, `sequence`, `tickId`, `playerID`, `resolverOutputs`, `resolvedAtTick`                                     |
| `RecordedServerEvent`    | `sequence`, `tickId`, `typeIdentifier`, `payload`, `target`                                                       |

## Using ReevaluationMonitor

The `SwiftStateTreeReevaluationMonitor` module provides a web-based UI for visualizing replay:

### Server Setup

```swift
import SwiftStateTreeReevaluationMonitor

// Create factory for your Land types
struct MyReevaluationFactory: ReevaluationTargetFactory {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "game":
            return try await ReevaluationRunnerImpl(
                definition: GameLand.definition,
                recordFilePath: recordFilePath
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

// Register the monitor land
let monitorService = ReevaluationRunnerService(factory: MyReevaluationFactory())
server.registerLand(ReevaluationMonitor.makeLand(), services: [monitorService])
```

### WebClient

Connect to the monitor land and send actions:

```typescript
// Start verification
await client.sendAction("startVerification", {
  landType: "game",
  recordFilePath: "/path/to/recording.jsonl",
});

// Pause/Resume
await client.sendAction("pauseVerification", {});
await client.sendAction("resumeVerification", {});
```

## Verification

### State Hash Proves Reevaluation

The per-tick `stateHash` is a deterministic FNV-1a64 hash of the full state snapshot. When live and replay produce the same hash for every tick, the state transition logic is deterministic. Server events are derived from the same handlers and inputs; recording them allows an additional consistency check.

### Server Event Verification

When `enableLiveStateHashRecording: true`, the server also records server events (`ctx.emitEvent()`) per tick. During reevaluation with `--verify`, the runner compares recorded vs emitted server events. A mismatch indicates non-determinism in event emission (e.g., ordering or payload differences).

### Field-Level State Diff (Debug)

For deep debugging of hash mismatches, you can record the full per-tick state snapshot alongside the main record and then use `--diff-with` to produce field-level diffs during reevaluation.

**Step 1 – Enable state snapshot recording on the server:**

```bash
ENABLE_STATE_SNAPSHOT_RECORDING=true ./YourServer
```

When this env var is set, the recorder writes a `*-state.jsonl` file alongside the main `.json` record. Each line is:

```json
{"tickId": 42, "stateSnapshot": { ... }}
```

**Step 2 – Run reevaluation with `--diff-with`:**

```bash
swift run ReevaluationRunner \
  --input path/to/recording.json \
  --diff-with path/to/recording-state.jsonl
```

Any field-level differences between recorded and computed state are printed to stderr:

```
[tick 42] DIFF at players.p1.position.v.x: recorded=98100 computed=0
[tick 42] DIFF at players.p1.position.v.y: recorded=35689 computed=0
```

> **Note:** `ENABLE_STATE_SNAPSHOT_RECORDING` is intended for debug sessions only. It increases memory usage and I/O per tick.

## Best Practices

1. **Keep handlers deterministic** - Avoid using `Date()`, `random()`, external API calls directly in handlers
2. **Use Resolvers for non-deterministic data** - Move async/non-deterministic operations to Resolvers
3. **Enable state hash recording** - Set `enableLiveStateHashRecording: true` for verification
4. **Use `emitEvent` not `spawn + sendEvent`** - Ensures deterministic event ordering

## Related Documentation

- [Runtime Mechanism](runtime.md) - Event Queue and Tick execution model
- [Resolver Mechanism](resolver.md) - How to handle non-deterministic operations
- [Design: Re-evaluation vs Traditional Replay](../../Notes/design/DESIGN_REEVALUATION_REPLAY.md) - Conceptual deep dive
