# Generic Replay Land v2 — Design Document

**Branch:** `feature/generic-replay-land-v2`
**Status:** Planning
**Supersedes:** `feature/generic-replay-land` (v1, abandoned)

---

## Why v1 Was Abandoned

v1 (branch `feature/generic-replay-land`) was a working proof-of-concept but introduced
unnecessary risk by modifying core pipeline files:

| File modified in v1 | Risk |
|---|---|
| `Sources/SwiftStateTree/Runtime/LandKeeper.swift` | Removed `mode == .live` guard in `flushOutputs` — could affect all live lands |
| `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` | Added `& Decodable` constraint, changing public API signature |

The original separation of concerns (live path vs reevaluation path in `LandKeeper`) existed
for good reasons and should not be disturbed.

**Rule for v2:** New code ONLY in `SwiftStateTreeReevaluationMonitor/` and game-specific files.
Do NOT touch `LandKeeper.swift`, `TransportAdapter.swift`, or `ReevaluationFeature.swift`.

---

## Hard-Won Learnings from v1

### 1. StateSnapshot JSON Format

The reevaluation runner's `actualState` is always wrapped in a `{"values": {...}}` envelope.

```json
// What actualState?.base (as String) actually contains:
{
  "values": {
    "base": {"health": 100, "maxHealth": 100, "position": {"v": {"x": 64000, "y": 36000}}, "radius": 3},
    "monsters": {"1": {"health": 50, "position": {"v": {"x": 127066, "y": 12072}}, ...}},
    "players": {"EF198066-1074-431F-89D0-EA29F257D50C": {...}},
    "score": 0,
    "turrets": {}
  }
}
```

**Critical:** Must unwrap `"values"` before decoding into the State type.

### 2. Decode Order: Values Wrapper FIRST

**Bug in v1:** `decodeReplayState` tried direct JSON decode first. Because `HeroDefenseState`
uses `decodeIfPresent` for all fields, the decode "succeeds" with all-default values (empty
dicts, zero ints) when applied to the `{"values":{...}}` envelope — the field keys simply
aren't at the top level.

```swift
// WRONG (v1 original):
if let decoded = try? JSONDecoder().decode(type, from: data) { return decoded }
// ↑ This "succeeds" with all defaults! decodeIfPresent returns nil → keeps defaults.

// CORRECT:
// 1. Try "values" wrapper first
// 2. Fallback to direct decode
```

### 3. Dictionary String Keys in Snapshots

All dictionary keys are serialized as strings in `StateSnapshot`, regardless of the Swift type:

| Swift key type | JSON key |
|---|---|
| `PlayerID` (struct wrapping UUID String) | `"EF198066-1074-431F-89D0-EA29F257D50C"` |
| `Int` (monster/turret IDs) | `"1"`, `"2"`, `"3"` |

Custom `init(from decoder:)` must decode as `[String: Value]` and convert keys:

```swift
// PlayerID keys:
if let dict = try container.decodeIfPresent([String: PlayerState].self, forKey: .players) {
    players = Dictionary(uniqueKeysWithValues: dict.map { (PlayerID($0.key), $0.value) })
}
// Int keys:
if let dict = try container.decodeIfPresent([String: MonsterState].self, forKey: .monsters) {
    monsters = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
}
```

### 4. `@StateNodeBuilder` Does NOT Synthesize Decodable

The `@StateNodeBuilder` macro generates:
- `broadcastSnapshot(dirtyFields:)` (sync/diff methods)
- `isDirty()`, `getDirtyFields()`, `clearDirty()` (dirty tracking)
- `getSyncFields()`, `snapshotForSync(...)` etc.

It does NOT synthesize `Codable`/`Decodable`. Each state type that needs replay decoding
requires a manual `init(from decoder:)`.

### 5. Position2 / DeterministicMath Encoding

`Position2` is stored via its `IVec2` internal representation (1000x fixed-point):

```json
{"v": {"x": 64000, "y": 36000}}   // means position (64.0, 36.0) in game units
```

`Angle` is stored as `{"degrees": 90}`.
These types need their own `Decodable` conformances.

### 6. `@Sync` Property Wrappers and Dirty Flags After Decode

When `state = decoded` replaces the entire struct in a Tick handler:
- The decoded state comes from `JSONDecoder` → `init(from decoder:)` → `self.init()` → sets properties
- Property wrapper dirty flags may or may not be set, depending on wrapper setter implementation
- `isDirty()` may return `false` for the decoded state

**Consequence:** `extractAndComputeBroadcastDiff` falls through to `.all` mode (full snapshot,
no dirty-field filtering). This is correct and produces the right diff; it just misses the
dirty-tracking optimization. For replay lands this is acceptable.

### 7. `computeBroadcastDiffFromSnapshot` Seeds Cache on First Call

The first time `syncBroadcastOnlyFromTransport()` is called for a land instance, the broadcast
cache is empty. `computeBroadcastDiffFromSnapshot` seeds the cache with the current snapshot
and returns `[]` (empty diff). No patches are sent for that first tick.

This is by design. The client gets the full state via `firstSync` (via `lateJoinSnapshot`
which is independent of the broadcast cache). Subsequent ticks produce real diffs.

### 8. `GameConfigProviderService` Must Be Injected into Runner

`HeroDefenseLand`'s Tick handler starts with:
```swift
guard let configService = ctx.services.get(GameConfigProviderService.self) else { return }
```

If `GameConfigProviderService` is absent from the runner's services, the entire game tick
handler is a no-op — no monsters spawn, no monsters move. State hash would still change
but for trivial reasons.

The `GameServerReevaluationFactory` in `GameServer/main.swift` handles this:
```swift
services.register(GameConfigProviderService(provider: DefaultGameConfigProvider()),
                  as: GameConfigProviderService.self)
```
Any custom factory must do the same.

### 9. Replay Record Behavior: Player Leave Mid-Session

Recording `3-hero-defense.json` (425 ticks):
- Tick 0: player joins
- Tick 325: player leaves (`OnLeave` → `players.removeValue(forKey:)`)
- Ticks 326–424: no players, monsters still spawn and move toward base

When viewed in a replay client, the player disappears at tick 325. This is **correct behavior**
(the recording faithfully captures the session). A replay viewer may want to handle the
"replay finished" phase differently (loop, freeze, show end-screen).

---

## Problems NOT Solved in v1

1. **No replay loop/freeze at end:** When all ticks are consumed, `GenericReplayLand` keeps
   ticking with the last decoded state. The client sees the state freeze. No "replay ended"
   notification exists.

2. **No fast-forward / seek:** The viewer can only play at 1× speed. No way to skip ahead.

3. **Pacing mismatch:** Runner sleeps 50ms per step; viewer Tick also runs every 50ms. In
   practice, CPU scheduling jitter means occasional missed or double-consumed frames.

4. **`requestSyncBroadcastOnly` vs `requestSyncNow`:** Replay only needs to broadcast (no
   per-player state). But if per-player fields need to be visible, `syncNow` is required.
   Current design assumes all replay-relevant fields are `@Sync(.broadcast)`.

---

## v2 Architecture (Planned)

### Core Constraint

**Zero changes to `LandKeeper.swift`, `TransportAdapter.swift`, `ReevaluationFeature.swift`.**

New files only in:
- `Sources/SwiftStateTreeReevaluationMonitor/` (generic replay infrastructure)
- `Examples/GameDemo/Sources/GameContent/States/` (Decodable conformances)
- `Examples/GameDemo/Sources/GameServer/main.swift` (registration, unchanged structure)

### Approach

Keep the same GenericReplayLand concept (`.live` mode + Tick handler) but:

1. Do NOT remove the `mode == .live` guard in `LandKeeper.swift` — it was there originally
   and GenericReplayLand already runs in `.live` mode so the guard is irrelevant anyway.

2. Add `& Decodable` constraint via a NEW overload (not modifying the existing
   `registerWithReevaluationSameLand`) — or accept it as an additive non-breaking extension.

3. Document the `decodeReplayState` "values wrapper first" rule prominently in code.

4. Consider adding a `ReplayEndedEvent` so the client knows when the replay is complete.

### File Plan

```
Sources/SwiftStateTreeReevaluationMonitor/
  GenericReplayLand.swift         ← new (same as v1 concept, cleaner)
  ReplayTickEvent.swift           ← new (split from GenericReplayLand for clarity)

Examples/GameDemo/Sources/GameContent/States/
  HeroDefenseState+Decodable.swift  ← new (extension-only, not modifying original struct)
  PlayerState+Decodable.swift       ← new
  MonsterState+Decodable.swift      ← new
  TurretState+Decodable.swift       ← new
  BaseState+Decodable.swift         ← new
```

Using `+Decodable` extensions keeps the original state files untouched.

---

## Checklist Before Starting v2 Implementation

- [ ] Verify `LandKeeper.swift` on main has the original `mode == .live` guard (should not be removed)
- [ ] Verify `ReevaluationFeature.swift` on main has the original signature
- [ ] Verify `HeroDefenseReplayLand.swift` still exists on main
- [ ] Confirm `GameServerReevaluationFactory` in `main.swift` injects `GameConfigProviderService`
- [ ] Write `Decodable` extensions as separate `+Decodable.swift` files
- [ ] Unit test: `decodeReplayState` correctly unwraps `{"values":{...}}` format
- [ ] Unit test: `init(from decoder:)` handles string keys for `PlayerID` and `Int` dictionaries
- [ ] E2E test: verify entity counts via `verify-replay-record.ts`
