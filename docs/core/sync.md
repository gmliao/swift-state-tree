[English](sync.md) | [中文版](sync.zh-TW.md)

# Sync and Sync Strategies

StateTree synchronization relies on `@Sync` + `SyncPolicy`, with SyncEngine generating snapshots/diffs.

## Design Notes

- Sync rules can be declared on types (`@Sync`), decoupled from handler logic
- Support per-player filtering to avoid unnecessary data leakage or bandwidth waste
- Use snapshot/diff merge mode to reduce sync costs

## SyncPolicy Types

- `.serverOnly`: Not synced to client
- `.broadcast`: All clients receive same data
- `.perPlayerSlice()`: Dictionary-specific convenience method, automatically slices `[PlayerID: Element]` to sync only that player's slice (**high frequency use**, no filter needed)
- `.perPlayer((Value, PlayerID) -> Value?)`: Requires manual filter function, filter by player (applicable to any type, **low frequency use**, for scenarios requiring custom filter logic)
- `.masked((Value) -> Value)`: Same-type masking (all players see same masked value)
- `.custom((PlayerID, Value) -> Value?)`: Fully custom

### What a Filter Sees

A `.perPlayer` filter receives only the field's value and the player ID. It cannot read other fields of the state, the land, or a service. A filter must also be a pure function of those two arguments, since it runs in every sync for every player. When visibility depends on other state (positions, teams, fog of war), compute it where that state changes, usually in the tick or the handler, and store it next to the data, where the filter can read it:

```swift
@StateNodeBuilder
struct Entity: StateNodeProtocol {
    @Sync(.broadcast) var position: Position2 = Position2(x: 0, y: 0)
    @Sync(.serverOnly) var visibleTo: [PlayerID] = []  // set by the tick, never sent
}

@StateNodeBuilder
struct ArenaState: StateNodeProtocol {
    // Each player receives only the entities whose visibleTo contains them.
    @Sync(.perPlayer({ (entities: [String: Entity], playerID: PlayerID) in
        entities.filter { $0.value.visibleTo.contains(playerID) }
    }))
    var entities: [String: Entity] = [:]
}
```

The filter reads `visibleTo` from the value it is given, and `visibleTo` itself stays on the server. The GameDemo visibility-test land (`VisibilityTestLand.swift`) is a complete example.

### Nested State Nodes

A state node applies its own fields' policies wherever it sits: as a field, in an optional, in an array, or as the value of a `[String: X]` or `[PlayerID: X]` map, at any depth. Each client receives only what those policies allow, so per-player visibility can live inside the map's values:

```swift
@StateNodeBuilder
struct Unit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 100                     // every player
    @Sync(.serverOnly) var aiState: Int = 0                 // never sent
    @Sync(.perPlayerSlice()) var hints: [PlayerID: Int] = [:] // each player gets its own entry
}

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast) var units: [PlayerID: Unit] = [:]
}
```

Before 2026-11-05 (#178), a `@SnapshotConvertible` node inside a `[String: X]` or `[PlayerID: X]` map was sent with every field, server-only ones included. Recordings made before then hash differently; see [Re-evaluation](reevaluation.md#records-older-than-23-175).

## Snapshot and Diff

- snapshot: Complete state (including per-player filtering)
- diff: Only send changes (path-based patches)

SyncEngine maintains:

- broadcast cache: Shared by all players
- per-player cache: Independent for each player

## First Sync

`StateUpdate.firstSync` is sent once after player cache is first established,
avoiding race conditions between join snapshot and first diff.

## Dirty Tracking

`@Sync` marks dirty on write, used to reduce diff costs.
TransportAdapter can switch dirty tracking at runtime:

- Enabled: Only serialize dirty fields
- Disabled: Full snapshot on every sync

## Manual Sync

In handlers, you can request a deterministic sync through `ctx.requestSyncNow()` (or `ctx.requestSyncBroadcastOnly()`).
