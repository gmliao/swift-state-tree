[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land is the smallest runnable unit of server logic, responsible for defining join rules, behavior rules, and lifecycle.
`Land(...)` collects DSL nodes and generates `LandDefinition<State>`, executed by Runtime.

## Design Notes

- Land DSL only describes behavior, doesn't expose Transport details
- Handlers are synchronous; emit outputs via `ctx.emitEvent(...)` / `ctx.requestSync*()` and keep async I/O out-of-band (e.g., via Resolver).
- Event type registration (Client/ServerEvents) used for schema and validation

## Basic Structure

```swift
Land("demo", using: GameState.self) {
    AccessControl { ... }
    ClientEvents { ... }
    ServerEvents { ... }
    Rules { ... }
    Lifetime { ... }
}
```

## AccessControl

Controls room visibility and player limit:

- `AllowPublic(true|false)`
- `MaxPlayers(Int)`

## ClientEvents / ServerEvents

Register event types (used by schema/validation/tools):

```swift
ClientEvents {
    Register(ClickCookieEvent.self)
}

ServerEvents {
    Register(PongEvent.self)
}
```

Server events are notifications; the synced state is the source of truth. A session that is still joining gets the targeted events sent to it right after its firstSync, in emission order, and their effects are already in that firstSync (see [Transport](../transport/README.md#join-and-session-flow)).

## Rules

Rules block defines Join/Leave and Action/Event behavior:

- `CanJoin`: Validation before joining, returns `JoinDecision`
- `OnJoin` / `OnLeave`: Processing after joining or leaving
- `HandleAction`: Handle Action (with response)
- `HandleEvent`: Handle Client Event (no response)

```swift
Rules {
    CanJoin { state, session, ctx in
        .allow(playerID: PlayerID(session.playerID))
    }

    OnJoin { state, ctx in
        // mutate state
    }

    HandleAction(JoinAction.self) { state, action, ctx in
        return JoinResponse(status: "ok")
    }

    HandleEvent(ClickCookieEvent.self) { state, event, ctx in
        // mutate state
    }
}
```

### Actions that must apply at most once

The transport delivers an action at most once and doesn't deduplicate resends (see the SDK's [delivery semantics](../sdk/README.md#delivery-semantics-at-most-once)):
- **The outcome after a close is unknown.** A pending action rejected with `ConnectionClosedError` may or may not have been applied.
- **The SDK doesn't resend.** A resend is the app's choice, and the server applies it as a new request.
- **After a rejoin, use the firstSync state** to see whether an action took effect.
- **On a tick land, the response is an ACK: "queued", not "applied".** The handler runs in a later tick, and its return value doesn't reach the client. Read the result from state.

For an action that must not apply twice, a purchase for example, deduplicate in land state:
- the client puts an ID in the payload, chosen once per operation and sent again unchanged if it resends;
- the handler records the IDs it has applied in the state and ignores one it has seen.

In state, the check is part of the land's deterministic turn, so recordings, replay and reevaluation reproduce it. A table kept outside the state wouldn't be visible to them. The app bounds the history: a resend older than the bound applies again.

```swift
@StateNodeBuilder
struct ShopState: StateNodeProtocol {
    @Sync(.perPlayerSlice())
    var coins: [PlayerID: Int] = [:]

    /// Purchase IDs this land has applied, per player, newest last. Server-only: clients
    /// don't need it. Bounded by the app (see `maxAppliedPurchases`).
    @Sync(.serverOnly)
    var appliedPurchases: [PlayerID: [String]] = [:]

    init() {}
}

@Payload
struct BuyItemAction: ActionPayload {
    typealias Response = BuyItemResponse

    /// Chosen by the client once per purchase, and sent again unchanged if it resends.
    let purchaseID: String
    let itemID: String
    let price: Int
}

@Payload
struct BuyItemResponse: ResponsePayload {
    let applied: Bool
    let coins: Int
}

/// How many purchase IDs a player's history keeps; a resend older than that applies again.
let maxAppliedPurchases = 64

// In the land's Rules:
HandleAction(BuyItemAction.self) { (state: inout ShopState, action: BuyItemAction, ctx: LandContext) throws -> BuyItemResponse in
    let player = ctx.playerID
    let coins = state.coins[player] ?? 0
    var applied = state.appliedPurchases[player] ?? []
    // Already applied: change nothing.
    guard !applied.contains(action.purchaseID) else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    guard coins >= action.price else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    state.coins[player] = coins - action.price
    applied.append(action.purchaseID)
    if applied.count > maxAppliedPurchases {
        applied.removeFirst(applied.count - maxAppliedPurchases)
    }
    state.appliedPurchases[player] = applied
    return BuyItemResponse(applied: true, coins: coins - action.price)
}
```

- `appliedPurchases` is `.serverOnly`: clients don't need it, and it costs nothing on the wire.
- The history is per player. Keep the bound well above how many such actions a player can send while a resend is still possible.
- On a tick land the client sees `BuyItemResponse` only as the ACK. It reads `coins` from state instead.

## LandContext

Handlers receive `LandContext`, containing:

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata` (from join/JWT/guest)
- `services` (injected external services)
- `emitEvent(...)`, `requestSyncNow()`, `requestSyncBroadcastOnly()`

LandContext is request-scoped, avoid saving references.

## Resolver

`HandleAction`, `OnJoin`, `OnInitialize` etc. can declare resolvers.
Resolvers execute in parallel first, then synchronously enter handler after success.

## Lifetime

- `Tick(every:)`: Game gameplay logic updates (can modify state)
- `StateSync(every:)`: State synchronization (read-only callback, will be called)
- `DestroyWhenEmpty(after:)`: Auto-close empty rooms
- `PersistSnapshot(every:)`: Snapshot period
- `OnInitialize` / `OnFinalize` / `AfterFinalize` / `OnShutdown`
- `OnInitialize(resolvers:onResolverFailure:)`: a throwing resolver fails the land's initialization by default (`.failLand`); `.continue` runs OnInitialize without the resolvers' outputs. See [Resolver deadline](resolver.md#deadline)

```swift
Lifetime {
    // Game logic updates (20Hz)
    Tick(every: .milliseconds(50)) { (state: inout GameState, ctx: LandContext) in
        // Use ctx.tickId (Int64) for deterministic, replay-compatible logic
        if let tickId = ctx.tickId {
            let tickIntervalSeconds = 0.05  // 50ms = 0.05s
            let gameTime = Double(tickId) * tickIntervalSeconds
            state.position += state.velocity * tickIntervalSeconds
        }
    }
    
    // Network synchronization (10Hz)
    // Callback is read-only and will be called during sync - do NOT modify state
    StateSync(every: .milliseconds(100)) { (state: GameState, ctx: LandContext) in
        // Read-only callback - will be called during sync
        // Use for logging, metrics, or other read-only operations
        // Network sync mechanism triggers network synchronization after callback
    }
    // If StateSync is not set, it auto-configures to match tick interval
}
```

**Note**: `Tick` is the only source of state mutations for replay functionality. `StateSync` only triggers state synchronization and does not modify state. The optional callback is read-only and will be called during sync operations for logging, metrics, or other read-only operations.
