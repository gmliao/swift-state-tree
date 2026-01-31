# Broadcast Encoding Optimization

## Problem

Currently, StateUpdate and Event encoding is done **per-player**, even for broadcast data that is identical for all players. This wastes CPU cycles on redundant encoding.

```
Current Flow:
┌─────────────────────────────────────────────────────────┐
│ 1. Compute broadcastDiff (once)                         │
│ 2. Compute perPlayerDiff (per player)                   │
│ 3. Merge: broadcastDiff + perPlayerDiff                 │
│ 4. Encode merged update (per player) ← REDUNDANT        │
│ 5. Send to each player                                  │
└─────────────────────────────────────────────────────────┘
```

**Root Cause**: `DynamicKeyTable` is per-player scoped, so even identical broadcast data produces different encoded bytes per player.

## Proposed Solution

**Separate broadcast and private updates into two transmissions:**

```
Proposed Flow:
┌─────────────────────────────────────────────────────────┐
│ Broadcast Update:                                       │
│ 1. Compute broadcastDiff (once)                         │
│ 2. Encode with Land-level KeyTable (once)               │
│ 3. Send same bytes to ALL players                       │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Private Update (only if needed):                        │
│ 4. Compute perPlayerDiff (per player)                   │
│ 5. Encode with per-player KeyTable                      │
│ 6. Send to individual player                            │
└─────────────────────────────────────────────────────────┘
```

## Key Changes

### 1. DynamicKeyTableStore Scope

```swift
// Current
struct DynamicKeyScope: Hashable {
    let landID: String
    let playerID: String  // per-player
}

// Proposed
enum DynamicKeyScope: Hashable {
    case broadcast(landID: String)                    // Land-level, shared
    case perPlayer(landID: String, playerID: String)  // Per-player
}
```

### 2. TransportAdapter.syncNow()

Separate encoding for broadcast and perPlayer updates:

```swift
// 1. Encode broadcast once
let broadcastUpdate = StateUpdate.diff(broadcastDiff)
let broadcastData = try encoder.encode(
    update: broadcastUpdate,
    scope: .broadcast(landID: landID)
)

// 2. Send broadcast to all
for sessionID in allSessions {
    try await transport.send(broadcastData, to: .session(sessionID))
}

// 3. For players with perPlayer updates
for (sessionID, playerID) in playersWithPrivateUpdates {
    let perPlayerUpdate = StateUpdate.diff(perPlayerDiff)
    let perPlayerData = try encoder.encode(
        update: perPlayerUpdate,
        scope: .perPlayer(landID: landID, playerID: playerID)
    )
    try await transport.send(perPlayerData, to: .session(sessionID))
}
```

### 3. Client SDK

Handle consecutive StateUpdate frames:

```typescript
// Client merges consecutive updates
onMessage(data) {
    const update = decode(data);
    if (update.type === 'stateUpdate') {
        this.pendingPatches.push(...update.patches);
        this.scheduleApply(); // Batch apply on next microtask
    }
}
```

## Impact Analysis

### Hero Defense Example (All Broadcast)

| Scenario | Monsters | Players | Patches/tick | Current Encoding | Optimized | Savings |
|----------|----------|---------|--------------|------------------|-----------|---------|
| Small    | 10       | 2       | ~15          | 2x               | 1x        | 50%     |
| Medium   | 20       | 4       | ~26          | 4x               | 1x        | **75%** |
| Large    | 50       | 8       | ~60          | 8x               | 1x        | **87.5%** |
| MMO      | 100      | 20      | ~120         | 20x              | 1x        | **95%** |

### When Most Effective

- Games with mostly broadcast state (like Hero Defense)
- High player count (10+)
- High entity count (monsters, bullets, etc.)
- Frequent state updates (20+ Hz tick rate)

### When Less Effective

- Games with mostly perPlayer state (private inventories, etc.)
- Low player count (1-2)
- Infrequent updates

## Implementation Estimate

| Component | Effort | Lines Changed |
|-----------|--------|---------------|
| DynamicKeyTableStore scope | Low | ~20 |
| TransportAdapter.syncNow() | Medium | ~50 |
| Protocol (no change needed) | None | 0 |
| Client SDK | Low | ~10 |
| **Total** | **Low-Medium** | **~100** |

## Trade-offs

| Aspect | Impact |
|--------|--------|
| **CPU Usage** | Reduced (fewer encodings) |
| **Bandwidth** | Neutral (same total data, possibly 1 extra frame header) |
| **Latency** | Neutral (parallel sends) |
| **Complexity** | Slightly increased (two update paths) |
| **Compatibility** | Backward compatible (same protocol) |

## Open Questions

1. **firstSync handling**: Send as single merged update, or two separate updates?
   - Recommendation: Single merged update for firstSync (simpler client logic)

2. **Empty broadcast optimization**: Skip broadcast frame if broadcastDiff is empty?
   - Recommendation: Yes, only send if non-empty

3. **Event batching**: Apply same optimization to events?
   - Recommendation: Yes, events can benefit similarly

## Related Files

- `Sources/SwiftStateTreeTransport/TransportAdapter.swift` - Main sync logic
- `Sources/SwiftStateTreeTransport/OpcodeJSONStateUpdateEncoder.swift` - JSON encoder
- `Sources/SwiftStateTreeTransport/OpcodeMessagePackStateUpdateEncoder.swift` - MessagePack encoder
- `Sources/SwiftStateTree/Sync/SyncEngine.swift` - Diff computation (already separated)
