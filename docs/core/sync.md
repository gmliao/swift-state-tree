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

A policy belongs to its declaration, not to each value. `@StateNodeBuilder` emits the `@Sync` argument once for the node type, and every instance filters through it:
- In a node type that isn't generic and isn't nested in a generic type, an extension or a function, the policy that filters is evaluated once, at its first use, and every instance shares it.
- In any other node type, it is evaluated each time it is used.
- In both cases the attribute's argument is also evaluated at each init that initializes the field through the attribute (an initial value, or `self.x = …` in an init), and that value is discarded. A factory such as `.perPlayerSlice()` therefore still runs at every such init. An init that builds the wrapper by hand doesn't evaluate it.

The policy is the one in the attribute. A wrapper built by hand in an init (`_x = Sync(wrappedValue: v, .serverOnly)`) doesn't change it: the policy passed there is ignored.

So a policy expression must be pure, like its filter: callable from any context, since the sync may run on another executor than the one that created the state, and depending on nothing that changes after the land starts.

### Nested State Nodes

A state node applies its own fields' policies wherever it sits: as a field, in an optional, in an array, or as the value of a `[String: X]` or `[PlayerID: X]` map, at any depth. A child sees what its parent's filter left, and its own policy is then applied on top:

| Parent \ child | `.broadcast` | `.serverOnly` | `.masked` | `.perPlayer` / `.perPlayerSlice()` / `.custom` |
|---|---|---|---|---|
| `.broadcast` | everyone | never sent | everyone, masked | **rejected** |
| `.perPlayer` / `.perPlayerSlice()` / `.custom` | whoever sees the parent | never sent | whoever sees the parent, masked | both filters apply |
| `.masked` (a node-typed field) | the mask runs first, then the children's policies | | | |
| `.serverOnly` | nothing below is sent | | | |

**A player-dependent field can't have a `.broadcast` ancestor** (#179), through any container. A broadcast field is encoded once, without a player, and sent to everyone, so a per-player field below it would not reach its player in diffs. `LandTypeRegistry.init` (so every host that serves the land), `NIOLandHost.register`, `SchemaExtractor.extract` and `SchemaGenCLI.generateSchema` reject such a state with a `SyncPolicyNestingError` that names each field and its broadcast ancestor; `SyncPolicyNesting.validate(_:)` runs the same check. A plain struct (not a state node) is looked into through a default instance, since the encoder walks its stored properties like a child's; one the check can't see, such as an element of an empty array, is refused when the broadcast encoding meets it (`SyncError.unsupportedValue`). A policy the macro can't read (not written as `.name` or `.name(...)`) fails closed, and every `@Sync` property needs an explicit type. Keep per-player data in a top-level per-player field instead:

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

### Synced State Is Made of Value Types

Every `@Sync` field holds value types (structs, enums, collections of them, state nodes) at any depth (#464). The diff compares values, and debug builds check a throwing handler's writes against a copy taken before the handler ([Runtime](runtime.md#inputs-and-turns)); a write through a shared object escapes both. So a class in synced state is refused:
- **At registration.** `LandTypeRegistry.init` (so every host that serves the land), `NIOLandHost.register`, `SchemaExtractor.extract` and `SchemaGenCLI.generateSchema` throw a `SyncValueSemanticsError` that names each field and class, for example `GameState.inventory: Inventory is a class; synced state must be value types`. The check walks every synced field's type, `.serverOnly` ones included, through optionals, arrays, sets, dictionary keys and values, and nested state nodes. It looks into plain structs, tuples, enum payloads and existential fields (`any P`) through a default instance.
- **When the state is converted.** A class the check couldn't see (one stored later in an existential field, one in an enum case the default instance doesn't take, or one added to a collection that was empty at registration) makes the conversion throw `SyncError.unsupportedValue`. A dictionary key is the exception: it is converted through its description, so a class held inside a key of a value type (a `CustomStringConvertible` struct with a class property) is refused only at registration, when the default instance's first key holds one (the check samples a dictionary's first entry). Conversion runs for every sync, so that land's syncs fail (a `.serverOnly` field is converted only when the state is recorded or hashed, and by the debug check of a throwing handler's writes, so those fail instead); when the class is in an event payload, the sync-output verifier can't canonicalize the event and reports its events scope as unverifiable.

Make the type a struct or an enum. A reference the land needs but doesn't sync, such as a cache or a service handle, goes in an `@Internal` field, which isn't checked. A `SnapshotValueConvertible` type is converted by its own `toSnapshotValue()`, but its storage is still checked: a conforming class is refused, and so is a conforming struct whose default instance holds one.

**Breaking change (2026-11-10).** Before #464 a class in synced state was encoded through its stored properties, and only an object graph that referred back to itself was refused. A land whose state holds a class now fails to register.

## Snapshot and Diff

- snapshot: Complete state (including per-player filtering)
- diff: Only send changes (path-based patches)

SyncEngine maintains:

- broadcast cache: Shared by all players
- per-player cache: Independent for each player

### Rules for Synced Value Types

The typed sync diff (`USE_SYNC_TABLES`, experimental and off by default) keeps the last value it sent for each broadcast field as a native Swift value, and compares the live value against it with `==` before it builds any patch. It relies on these rules. Types that follow them work the same on today's path. With `TYPED_LEAF_VALUES` (also experimental), a changed field of a built-in leaf type is converted by its typed form instead of the general conversion; the patches and bytes are the same, and a user's own types keep the general conversion.

- **A plain value gets the typed comparison only if it is `Equatable`.** A synced struct, enum or collection that isn't `Equatable` is converted and diffed the way it is today. The frames are the same bytes either way; only the cost differs.
- **`==` must not hide a change.** If `a == b`, the two values must convert to the same snapshot. A custom `==` that ignores a synced property breaks this: the change is never sent. Debug builds report it when they see it.
- **Conversion depends on the value alone.** `toSnapshotValue()` must return the same snapshot for the same value every time, so it must not read a clock, a counter or other outside state.
- **Map keys and player IDs are sent in NFC.** A dictionary key is written in Unicode normalization form C when the state is converted, and a `PlayerID` holds its raw value in NFC from its creation, so one key has one spelling on the wire whichever spelling the server was given (Swift's `String ==` already treats them as one key). ASCII text is unchanged. A type that builds its own object in a hand-written `toSnapshotValue()` must write NFC keys itself: its keys are sent as written.
- **Synced values have value semantics.** A synced value must not share mutable state with the live state. A field whose type is a class, or an optional, array, dictionary, set or state node that holds one, is detected and diffed the way it is today. A class hidden inside a struct, an enum or an existential can't be detected: if it is mutated in place, no patch is sent.
- **The build and the log tell you which fields miss out.** `@StateNodeBuilder` warns at compile time for each synced field whose type isn't `Equatable` (the warning names the field and its type; there is no way to silence it other than making the type `Equatable`). A field whose type names a generic parameter of its node is not checked at compile time, because whether it is `Equatable` depends on what the parameter is bound to; the log covers it. The other reasons can't be seen by the compiler, so the first land of a state type that starts on the typed diff logs one warning that lists every field diffed the old way, with the reason for each.

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
