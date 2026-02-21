# Server Event Recording & Verification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Record server events in live recording and verify reevaluation produces identical events. Document that frame hash proves reevaluation.

**Architecture:** Extend ReevaluationTickFrame and ReevaluationRecorder; record in LandKeeper.flushOutputs; add verification in ReevaluationEngine/Runner.

**Tech Stack:** Swift 6, SwiftStateTree, existing reevaluation infrastructure.

---

## Task 1: Add serverEvents to ReevaluationTickFrame

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`

**Step 1: Add serverEvents field to ReevaluationTickFrame**

Add `serverEvents` with default empty array for backward compatibility:

```swift
public struct ReevaluationTickFrame: Codable, Sendable {
    public let tickId: Int64
    public let stateHash: String?
    public let actions: [ReevaluationRecordedAction]
    public let clientEvents: [ReevaluationRecordedClientEvent]
    public let lifecycleEvents: [ReevaluationRecordedLifecycleEvent]
    public let serverEvents: [ReevaluationRecordedServerEvent]  // NEW

    public init(
        tickId: Int64,
        stateHash: String? = nil,
        actions: [ReevaluationRecordedAction],
        clientEvents: [ReevaluationRecordedClientEvent],
        lifecycleEvents: [ReevaluationRecordedLifecycleEvent],
        serverEvents: [ReevaluationRecordedServerEvent] = []  // NEW, default for old records
    )
}
```

**Step 2: Update all ReevaluationTickFrame construction sites**

Search for `ReevaluationTickFrame(` and add `serverEvents: []` (or pass the actual array) to each call. Locations: ActionRecorder.swift (ReevaluationRecorder), tests.

**Step 3: Run tests**

```bash
swift test --filter ReevaluationReplayCompatibilityTests
swift test --filter ReevaluationEngineTests
```

Expected: PASS (may need to fix test fixtures that construct ReevaluationTickFrame).

**Step 4: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ActionRecorder.swift
git commit -m "feat(reevaluation): add serverEvents to ReevaluationTickFrame"
```

---

## Task 2: Add recordServerEvents to ReevaluationRecorder

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`

**Step 1: Implement recordServerEvents**

Add method to ReevaluationRecorder actor:

```swift
/// Record server events emitted for a specific tick.
public func recordServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) {
    if tickId != currentTickId {
        if let frame = currentFrame {
            frames.append(frame)
        }
        currentTickId = tickId
        currentFrame = ReevaluationTickFrame(
            tickId: tickId,
            stateHash: nil,
            actions: [],
            clientEvents: [],
            lifecycleEvents: [],
            serverEvents: events
        )
        return
    }
    guard let frame = currentFrame else {
        currentFrame = ReevaluationTickFrame(
            tickId: tickId,
            stateHash: nil,
            actions: [],
            clientEvents: [],
            lifecycleEvents: [],
            serverEvents: events
        )
        return
    }
    currentFrame = ReevaluationTickFrame(
        tickId: frame.tickId,
        stateHash: frame.stateHash,
        actions: frame.actions,
        clientEvents: frame.clientEvents,
        lifecycleEvents: frame.lifecycleEvents,
        serverEvents: events
    )
}
```

**Step 2: Run tests**

```bash
swift test --filter ReevaluationEngineTests
```

**Step 3: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ActionRecorder.swift
git commit -m "feat(reevaluation): add recordServerEvents to ReevaluationRecorder"
```

---

## Task 3: Record server events in LandKeeper (live mode)

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`

**Step 1: In flushOutputs, record to ReevaluationRecorder when live**

In `flushOutputs(forTick:)`, after the `switch mode` block's live branch (which sends to transport), add:

```swift
case .live:
    for item in toFlush {
        await transport?.sendEventToTransport(item.event, to: item.target)
    }
    // Record server events for verification when reevaluation recording is enabled
    if let recorder = reevaluationRecorder, !toFlush.isEmpty {
        let records = toFlush.map { item in
            ReevaluationRecordedServerEvent(
                kind: "serverEvent",
                sequence: item.sequence,
                tickId: item.tickId,
                typeIdentifier: item.event.type,
                payload: item.event.payload,
                target: ReevaluationEventTargetRecord.from(item.target)
            )
        }
        await recorder.recordServerEvents(tickId: tickId, events: records)
    }
```

**Step 2: Run tests**

```bash
swift test --filter LandKeeperReevaluationOutputModeTests
swift test --filter ReevaluationEngineTests
```

**Step 3: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/LandKeeper.swift
git commit -m "feat(reevaluation): record server events in live mode"
```

---

## Task 4: Add getServerEvents to ReevaluationSource

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ActionSource.swift`

**Step 1: Add protocol method**

Add to ReevaluationSource:

```swift
/// Get recorded server events for a specific tick (for verification).
func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent]
```

**Step 2: Implement in JSONReevaluationSource**

```swift
public func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] {
    framesByTickId[tickId]?.serverEvents ?? []
}
```

**Step 3: Update any other ReevaluationSource implementations**

Search for `ReevaluationSource` conformance; add default or implementation.

**Step 4: Run tests**

```bash
swift test --filter ReevaluationEngineTests
```

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ActionSource.swift
git commit -m "feat(reevaluation): add getServerEvents to ReevaluationSource"
```

---

## Task 5: Add server event verification to ReevaluationEngine

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift`

**Step 1: Extend RunResult with server event mismatches**

Add to RunResult:

```swift
public let serverEventMismatches: [(tickId: Int64, expected: [ReevaluationRecordedServerEvent], actual: [ReevaluationRecordedServerEvent])]
```

**Step 2: In run loop, compare recorded vs emitted**

After each tick, get `recordedServerEvents` from source. Compare with `emittedServerEvents` from sink. If different, append to mismatches. Use a helper to compare two `[ReevaluationRecordedServerEvent]` (count, order, typeIdentifier, payload equality).

**Step 3: Add optional verifyServerEvents parameter**

When `verifyServerEvents: Bool = false`, fail or report when mismatches non-empty. Or always compute mismatches and let caller decide.

**Step 4: Run tests**

```bash
swift test --filter ReevaluationEngineTests
```

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift
git commit -m "feat(reevaluation): add server event verification to ReevaluationEngine"
```

---

## Task 6: Wire verification into ReevaluationRunner (Demo + GameDemo)

**Files:**
- Modify: `Examples/Demo/Sources/ReevaluationRunner/main.swift`
- Modify: `Examples/GameDemo/Sources/ReevaluationRunner/main.swift`

**Step 1: When verify is true, check serverEventMismatches**

After state hash verification, if `result.serverEventMismatches` is non-empty, print mismatches and exit with error.

**Step 2: Run ReevaluationRunner manually**

Record a session with server events (e.g., Hero Defense), then run verify. Ensure it passes when events match.

**Step 3: Commit**

```bash
git add Examples/Demo/Sources/ReevaluationRunner/main.swift Examples/GameDemo/Sources/ReevaluationRunner/main.swift
git commit -m "feat(reevaluation): verify server events in ReevaluationRunner"
```

---

## Task 7: Update reevaluation documentation

**Files:**
- Modify: `docs/core/reevaluation.md`
- Modify: `docs/core/reevaluation.zh-TW.md`

**Step 1: Add section on state hash and server event verification**

- State hash proves deterministic reevaluation (same inputs → same state).
- Server events are recorded in live mode and compared during replay for additional consistency check.
- When `enableLiveStateHashRecording` is true, server events are also recorded.

**Step 2: Commit**

```bash
git add docs/core/reevaluation.md docs/core/reevaluation.zh-TW.md
git commit -m "docs: document state hash and server event verification"
```

---

## Task 8: Add unit test for server event recording

**Files:**
- Create or modify: `Tests/SwiftStateTreeTests/ReevaluationServerEventTests.swift` (or add to existing)

**Step 1: Write test**

- Land that emits server events in tick handler.
- Run in live mode with recording.
- Assert record contains serverEvents for that tick.
- Run reevaluation, assert emitted events match recorded.

**Step 2: Run test**

```bash
swift test --filter ReevaluationServerEvent
```

**Step 3: Commit**

```bash
git add Tests/SwiftStateTreeTests/ReevaluationServerEventTests.swift
git commit -m "test: add server event recording and verification test"
```

---

## Verification Checklist

- [ ] `swift test` passes
- [ ] New records include serverEvents when events are emitted
- [ ] ReevaluationRunner --verify fails on server event mismatch
- [ ] Documentation updated
- [ ] Backward compatibility: old records without serverEvents still load
