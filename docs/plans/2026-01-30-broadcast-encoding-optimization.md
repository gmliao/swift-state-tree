# Broadcast Encoding Optimization Implementation Plan
[English](2026-01-30-broadcast-encoding-optimization.md) | [中文版](2026-01-30-broadcast-encoding-optimization.zh-TW.md)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Encode broadcast state updates once per tick (opcode 107), send to all players, and keep per-player updates separate, so 500-room load tests complete without timeouts.

**Architecture:** Split tick sync into broadcast vs per-player. Broadcast updates are always sent via opcode 107 (with empty events when needed) and use a broadcast-scoped DynamicKeyTable. Per-player updates remain as standard StateUpdate frames using per-player DynamicKeyTables. firstSync remains a single merged update.

**Tech Stack:** Swift 6 (SwiftStateTreeTransport), TypeScript SDK (sdk/ts), Swift Testing, vitest, shell load test script.

---

### Task 1: Add scoped key tables to StateUpdate encoders (Swift)

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/StateUpdateEncoderProtocol.swift`
- Modify: `Sources/SwiftStateTreeTransport/OpcodeJSONStateUpdateEncoder.swift`
- Modify: `Sources/SwiftStateTreeTransport/OpcodeMessagePackStateUpdateEncoder.swift`
- Test: `Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift` (or add `StateUpdateEncoderScopedTests.swift`)

**Step 1: Write the failing test**

```swift
@Test("Broadcast scope reuses dynamic keys across players")
func testBroadcastScopeEncodesIdenticalBytes() throws {
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher())
    let landID = "land"
    let playerA = PlayerID("a")
    let playerB = PlayerID("b")
    let patches: [StatePatch] = [
        .init(path: "/monsters/dragon/hp", operation: .set(100))
    ]
    let update = StateUpdate.diff(patches)

    let dataA = try encoder.encode(update: update, landID: landID, playerID: playerA, playerSlot: nil, scope: .broadcast)
    let dataB = try encoder.encode(update: update, landID: landID, playerID: playerB, playerSlot: nil, scope: .broadcast)

    #expect(dataA == dataB)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`
Expected: FAIL (missing encode(scope:) or behavior not implemented)

**Step 3: Write minimal implementation**

- Add `StateUpdateKeyScope` enum (`broadcast`, `perPlayer`) and `StateUpdateEncoderWithScope` protocol.
- Update opcode encoders to conform and to select key table based on scope (broadcast uses per-land table, perPlayer uses per-player table).
- Keep JSONStateUpdateEncoder behavior unchanged (no dynamic keys).

**Step 4: Run test to verify it passes**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/StateUpdateEncoderProtocol.swift \
        Sources/SwiftStateTreeTransport/OpcodeJSONStateUpdateEncoder.swift \
        Sources/SwiftStateTreeTransport/OpcodeMessagePackStateUpdateEncoder.swift \
        Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift

git commit -m "Add broadcast/per-player key table scope"
```

---

### Task 2: Split broadcast vs per-player sync and limit opcode 107 to broadcast

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`
- Test: `Tests/SwiftStateTreeTransportTests/TransportAdapterOpcode107Tests.swift`

**Step 1: Write the failing test**

```swift
@Test("Opcode 107 is used only for broadcast updates")
func testOpcode107BroadcastOnly() async throws {
    // Arrange: two sessions, one has per-player diff
    // Act: run sync tick
    // Assert: broadcast update uses opcode 107, per-player update uses opcode 0-2
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter Opcode107BroadcastOnly`
Expected: FAIL

**Step 3: Write minimal implementation**

- In `syncNow`, build broadcast update and encode once.
- Send broadcast update as opcode 107 (events merged; use empty events when none).
- For players with per-player diff, send standard StateUpdate (no 107 merge).
- Keep firstSync as a single combined update (no split).
- Use `StateUpdateEncoderWithScope` when available; fall back to existing `StateUpdateEncoder` otherwise.

**Step 4: Run test to verify it passes**

Run: `swift test --filter Opcode107BroadcastOnly`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/TransportAdapter.swift \
        Tests/SwiftStateTreeTransportTests/TransportAdapterOpcode107Tests.swift

git commit -m "Send opcode 107 only for broadcast updates"
```

---

### Task 3: SDK dynamic key maps for broadcast vs per-player

**Files:**
- Modify: `sdk/ts/src/core/protocol.ts`
- Modify: `sdk/ts/src/core/runtime.ts`
- Test: `sdk/ts/src/core/protocol.test.ts`

**Step 1: Write the failing test**

```ts
it('uses broadcast key map for opcode 107 only', () => {
  const broadcastMap = new Map<number, string>()
  const playerMap = new Map<number, string>()

  const broadcast = [107, [2, [123, [0, 'foo'], 1, 1]], []] // opcode 107 with one patch
  const perPlayer = [2, [123, [0, 'bar'], 1, 1]] // diff update

  decodeStateUpdateWithEventsArray(broadcast, broadcastMap)
  decodeStateUpdateArray(perPlayer, playerMap)

  expect(broadcastMap.get(0)).toBe('foo')
  expect(playerMap.get(0)).toBe('bar')
})
```

**Step 2: Run test to verify it fails**

Run: `cd sdk/ts && npm test -- protocol.test.ts`
Expected: FAIL

**Step 3: Write minimal implementation**

- Add `broadcastDynamicKeyMap` and `perPlayerDynamicKeyMap` in runtime.
- Refactor `decodeMessage` / `classifyAndDecode` to pick the correct map based on opcode 107 vs state update array.
- Ensure firstSync resets the correct map only (broadcast or per-player).

**Step 4: Run test to verify it passes**

Run: `cd sdk/ts && npm test -- protocol.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add sdk/ts/src/core/protocol.ts sdk/ts/src/core/runtime.ts sdk/ts/src/core/protocol.test.ts

git commit -m "Split broadcast/per-player dynamic key maps"
```

---

### Task 4: Full verification (required before completion claim)

**Step 1: Swift tests**

Run: `swift test --filter BroadcastScopeEncodesIdenticalBytes`  
Run: `swift test --filter Opcode107BroadcastOnly`

Expected: PASS

**Step 2: SDK tests**

Run: `cd sdk/ts && npm test -- protocol.test.ts`  
Expected: PASS

**Step 3: Load test (500 rooms)**

Run: `timeout 180 bash Examples/GameDemo/scripts/server-loadtest/run-server-loadtest.sh`

Expected: completes before timeout. If timeout occurs, immediately stop DemoServer/GameServer processes and re-check logs.

**Step 4: Report evidence**

Paste the exact command outputs (exit code + summary).

---

## Findings & Root Cause (Post-Implementation)

**Observed problem:** 500-room load test (messagepack + opcode 107) frequently exceeded the default timeout and sometimes logged warnings about events targeting sessions that were not fully joined.

**Root causes identified:**
1. **Opcode 107 packaging overhead**: Broadcast updates were encoded to `Data`, then immediately unpacked to rebuild a 107 frame. Server events were also encoded to `Data` and unpacked per event. This created extra CPU and allocation cost in the hot sync path.
2. **Targeted event delivery gap in 107 mode**: When per-player diffs were `.noChange`, targeted events could be queued but not sent, increasing backlog and delay.
3. **Serial disconnect path**: `LandRouter.onDisconnect` awaited each land’s `TransportAdapter.onDisconnect`, effectively serializing 2,500+ disconnects and OnLeave handling at shutdown.
4. **Slow shutdown path in load test**: The load test previously disconnected every session individually and waited for per-land empty destroy timers, increasing tail latency beyond the 180s guard.

**Fixes applied:**
- Direct MessagePack array encoding for opcode 107 (no pack→unpack roundtrip).
- Direct MessagePack event body encoding for server events (no pack→unpack roundtrip).
- Ensure targeted events are sent separately when per-player diff is `.noChange`.
- Dispatch `TransportAdapter.onDisconnect` asynchronously from `LandRouter`.
- Add `forceShutdown` for lands and call `shutdownAllLands()` in ServerLoadTest cleanup to end quickly.

**Result:** The 500-room ServerLoadTest completes within the 180s timeout after these changes.

## Capacity / “System Explosion” Estimate (Rule of Thumb)

You can estimate overload risk by comparing total required CPU time per second vs. available CPU time:

```
TotalWorkPerSecond ≈
  Rooms * (TickCost * TicksPerSecond
         + SyncCost * SyncsPerSecond
         + EncodeCost * SyncsPerSecond)
  + EventCost * EventsPerSecond

CPUUtilization ≈ TotalWorkPerSecond / (CoreCount * 1s)
```

When `CPUUtilization > 1.0`, the system is saturated; tail latency grows and timeouts appear. In practice, start degrading earlier (~0.7–0.8) due to allocation/GC pressure and scheduling overhead. This model helps identify which cost term (tick, sync, encode, events) dominates and where to optimize first.
