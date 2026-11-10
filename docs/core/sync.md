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

A state node applies its own fields' policies wherever it sits: as a field, in an optional, in an array, or as the value of a `[String: X]` or `[PlayerID: X]` map, at any depth. A child sees what its parent's filter left, and its own policy is then applied on top:

| Parent \ child | `.broadcast` | `.serverOnly` | `.masked` | `.perPlayer` / `.perPlayerSlice()` / `.custom` |
|---|---|---|---|---|
| `.broadcast` | everyone | never sent | everyone, masked | **rejected** |
| `.perPlayer` / `.perPlayerSlice()` / `.custom` | whoever sees the parent | never sent | whoever sees the parent, masked | both filters apply |
| `.masked` (a node-typed field) | the mask runs first, then the children's policies | | | |
| `.serverOnly` | nothing below is sent | | | |

**A player-dependent field can't have a `.broadcast` ancestor** (#179), through any container. A broadcast field is encoded once, without a player, and sent to everyone, so a per-player field below it would not reach its player in diffs. `LandTypeRegistry.init` (so every host that serves the land), `NIOLandHost.register`, `SchemaExtractor.extract` and `SchemaGenCLI.generateSchema` reject such a state with a `SyncPolicyNestingError` that names each field and its broadcast ancestor; `SyncPolicyNesting.validate(_:)` runs the same check. A plain struct or class (not a state node) is looked into through a default instance, since the encoder walks its stored properties like a child's; one the check can't see, such as an element of an empty array, is refused when the broadcast encoding meets it (`SyncError.unsupportedValue`). A policy the macro can't read (not written as `.name` or `.name(...)`) fails closed, and every `@Sync` property needs an explicit type. Keep per-player data in a top-level per-player field instead:

```swift
@StateNodeBuilder
struct Unit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 100        // every player
    @Sync(.serverOnly) var aiState: Int = 0    // never sent
    @Sync(.masked({ $0 / 10 * 10 })) var shield: Int = 0 // every player, rounded
}

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast) var units: [PlayerID: Unit] = [:]
    // Per-player data for the units, at the top level: each player gets its own entry.
    @Sync(.perPlayerSlice()) var hints: [PlayerID: [PlayerID: Int]] = [:]
}
```

Before 2026-11-05 (#178), a `@SnapshotConvertible` node inside a `[String: X]` or `[PlayerID: X]` map was sent with every field, server-only ones included. Recordings made before then hash differently; see [Re-evaluation](reevaluation.md#records-older-than-23-175).

## Snapshot and Diff

- snapshot: Complete state (including per-player filtering)
- diff: Only send changes (path-based patches)

SyncEngine maintains:

- broadcast cache: Shared by all players
- per-player cache: Independent for each player

### Rules for Synced Value Types

The typed sync diff (`USE_SYNC_TABLES`, experimental and off by default) keeps the last value it sent for each broadcast field as a native Swift value, and compares the live value against it with `==` before it builds any patch. It relies on these rules. Types that follow them work the same on today's path.

- **A plain value gets the typed comparison only if it is `Equatable`.** A synced struct, enum or collection that isn't `Equatable` is converted and diffed the way it is today. The frames are the same bytes either way, with one known exception on the typed side: a value map whose key changes only its Unicode normalization form (NFC ↔ NFD) keeps the old spelling (#446). Apart from that, only the cost differs.
- **`==` must not hide a change.** If `a == b`, the two values must convert to the same snapshot. A custom `==` that ignores a synced property breaks this: the change is never sent. Debug builds report it when they see it.
- **Conversion depends on the value alone.** `toSnapshotValue()` must return the same snapshot for the same value every time, so it must not read a clock, a counter or other outside state.
- **Synced values have value semantics.** A synced value must not share mutable state with the live state. A field whose type is a class, or an optional, array, dictionary, set or state node that holds one, is detected and diffed the way it is today. A class hidden inside a struct, an enum or an existential can't be detected: if it is mutated in place, no patch is sent.
- **The build and the log tell you which fields miss out.** `@StateNodeBuilder` warns at compile time for each synced field whose type isn't `Equatable` (the warning names the field and its type; there is no way to silence it other than making the type `Equatable`). The other reasons can't be seen by the compiler, so the first land of a state type that starts on the typed diff logs one warning that lists every field diffed the old way, with the reason for each.

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
