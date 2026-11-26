[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land is the smallest runnable unit of server logic, responsible for defining join rules, behavior rules, and lifecycle.
`Land(...)` collects DSL nodes and generates `LandDefinition<State>`, executed by Runtime.

## Design Notes

- Land DSL only describes behavior, doesn't expose Transport details
- Handlers are synchronous; emit outputs via `ctx.emitEvent(...)` / `ctx.requestSync*()` and keep async I/O out-of-band (e.g., via Resolver).
- Event type registration (Client/ServerEvents) used for schema and validation
- Handler closures don't name their types: the state type comes from `Land(_:using:)`, and each input type from the `.self` argument of its handler

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

A land registers each client event it handles, and handles each client event it registers. Registration refuses a land whose two lists disagree: an event registered with no `HandleEvent`, or an event handled with no `Register`. The error, `LandRegistrationError.clientEventMismatches`, names each such event and the side it's missing. A keeper built without registration refuses the land when it initializes.

Server events are notifications; the synced state is the source of truth. A session that is still joining gets the targeted events sent to it right after its firstSync, in emission order, and their effects are already in that firstSync (see [Transport](../transport/README.md#join-and-session-flow)).

## Rules

Rules block defines Join/Leave and Action/Event behavior:

- `CanJoin`: Validation before joining, returns `JoinDecision`
- `OnJoin` / `OnLeave`: Processing after joining or leaving
- `HandleAction`: Handle Action (returns the action's declared `Response`)
- `HandleEvent`: Handle Client Event (no response)

Handler bodies don't throw; an input that can be refused uses `validate` and `apply` ([Two-Phase Handlers](#two-phase-handlers)).

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

### Two-Phase Handlers

Input handlers can't throw after they write (#586). The single-closure `HandleAction`, `HandleEvent`, `HandleServerInput`, `OnJoin` and `OnLeave` take bodies that don't throw. An input that can be refused is declared in two stages, `validate` and `apply`:

```swift
HandleAction(BuyAction.self,
    validate: { state, action, ctx in
        guard let item = state.shop[action.itemID] else { throw ShopError.notFound }
        guard (state.players[ctx.playerID]?.gold ?? 0) >= item.price else { throw ShopError.noGold }
        return BuyPlan(item: item)
    },
    apply: { state, action, plan, ctx in
        state.players[ctx.playerID]?.gold -= plan.item.price
        state.players[ctx.playerID]?.items.append(plan.item)
        return BuyResponse(ok: true)
    })
```

| Step | When | Does | Can't |
|---|---|---|---|
| resolve (`resolvers:`) | async, outside the turn, before it | loads data (a database, a remote call, a clock); its output is recorded | touch the state |
| `validate` | sync, in the turn | reads the state (a constant) and the context; throws to refuse; returns the plan | write the state, emit, request a sync |
| `apply` | sync, in the same turn, right after `validate` | writes the state, emits events, returns the response | throw |

- With nothing to pass, `validate` returns `Void` and `apply` takes `(inout State, Action, LandContext)`.
- `HandleEvent(_:validate:apply:)` and `HandleServerInput(_:validate:apply:)` take the same two forms; their `apply` returns `Void`. `HandleAction` takes `resolvers:` in both forms; both stages then get the outputs after the action: `validate: { state, action, outputs, ctx in … }`, `apply: { state, action, outputs, plan, ctx in … }`.
- `validate` borrows the state: no copy is made. It runs right before `apply` in the same turn, so what it checked still holds when `apply` writes.
- A `validate` throw fails that input alone, with nothing written and nothing emitted. The action's caller gets the error (`ACTION_HANDLER_ERROR`; on a tick land the caller already got its ACK at intake), an event's error goes to the client as an error payload (only on a tickless land, where the event waits for its input turn; on a tick land the event is applied in the next tick, so there the refusal is only logged), and a server input's is logged ([Runtime: Inputs and Turns](runtime.md#inputs-and-turns)).
- An action body and `apply` return the action's declared `Response` (#561). Returning another type doesn't compile.

#### ValidateContext

`validate` gets a `ValidateContext`, not a `LandContext`:

- **Available:** `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`, `isGuest`, `metadata`, `tickId`, `playerSlot`, `logger`, and `services`, restricted to `ReadOnlyLandService` types.
- **Not available:** `emitEvent`, `requestSyncNow()` / `requestSyncBroadcastOnly()`, server inputs, random numbers, scheduling.

`ReadOnlyLandService` is a marker protocol and a contract the compiler can't check: the service only reads, and answers the same for the same inputs, because replay runs `validate` again. Data that isn't deterministic (a clock, a remote call, a random source) belongs in a resolver, whose output is recorded. A service registered under an existential type (`register(x, as: (any P).self)`) can't be fetched through the marker; register it under its concrete type.

#### One Handler per Type

A land declares one `HandleAction` per action type, one `HandleEvent` per client-event type and one `HandleServerInput` per server-input type. A second declaration is refused at registration with `LandRegistrationError.duplicateHandlers`, which names the type and the `fileID:line` of both declarations. A keeper built without registration refuses it at initialization too. Inputs are dispatched by name, so two distinct types that share a name are refused the same way (#599): two action types whose names, last components or schema names meet (`Ping` and `PingAction`, or `A.Move` and `B.Move`), two server-input types with one name, and two registered client- or server-event types with one event name (`Hit` and `HitEvent`).

#### What the Compiler Can't Stop

- A `validate` that isn't deterministic: one that reads global mutable state or a clock, or calls a service that conforms to `ReadOnlyLandService` but doesn't keep its contract. Replay runs `validate` again and can decide differently.
- A write through a class reference held in the state. State can't hold classes: a state field's value is `PlainData`, checked at compile time (#464, [Sync](sync.md#synced-state-is-made-of-value-types)).
- Side effects in `validate`, such as logging: replay repeats them.

### Join Checks

`OnJoin` can't fail: whether a player may join is `CanJoin`'s decision, made at join intake. `OnJoin` applies in a later turn, so a `CanJoin` check on state that other inputs change can be stale by then (an in-turn join check is tracked in #588). Keep such state-dependent checks out of `CanJoin`, and handle a joiner that no longer fits in `OnJoin`: make them a spectator, or emit an event asking them to leave. `MaxPlayers` is unaffected: it is checked when the player is inserted, counting the joiners still pending. `OnLeave` can't fail either: a leave always happens.

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
HandleAction(BuyItemAction.self) { state, action, ctx in
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
- The checks here don't refuse the action, they answer it (`applied: false`), so one body that can't throw is enough. An action that should fail with an error throws from `validate` instead, which writes nothing ([Two-Phase Handlers](#two-phase-handlers)).

## Helpers and `@Land`

A land's rules are the game's rules: who can join, how inputs change the state, how time advances, which events exist. A helper is a function that returns part of them, such as `chatRules()`, the chat rules. Put the land's builder on it, with the land's state type, and return `LandRules` with the same types. Its closures infer their types as they do inside `Land(_:using:)`:

```swift
@LandDSL<GameState, NoServices>
func joinRules() -> LandRules<GameState, NoServices> {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

let land = Land("game", using: GameState.self) {
    joinRules()
    Rules { joinRules() }
}
```

`NoServices` is the services type of a land without services. Typealiases give a shorter spelling of the same helper: `typealias GameDSL = LandDSL<GameState, NoServices>` and `typealias GameRules = LandRules<GameState, NoServices>`, then `@GameDSL func joinRules() -> GameRules`.

A helper is spliced only into a land with its state type and services type. One built for another state, or for other services, doesn't compile where it's spliced. A helper for several lands is generic: over a protocol their states share, and over the services type, so lands with any services can use it:

```swift
protocol HasPlayers: StateNodeProtocol {
    var players: [PlayerID: Int] { get set }
}

@LandDSL<S, Svc>
func leaveRules<S: HasPlayers, Svc: Sendable>() -> LandRules<S, Svc> {
    OnLeave { state, ctx in state.players[ctx.playerID] = nil }
}

let game = Land("game", using: GameState.self) { leaveRules() }
let lobby = Land("lobby", using: LobbyState.self, services: LobbyServices.self) { leaveRules() }
```

A land declares some nodes once: `AccessControl`, `CanJoin`, `OnJoin`, `OnLeave`, and each setting in `Lifetime` (`Tick`, `StateSync`, `DestroyWhenEmpty`, `PersistSnapshot`, `OnInitialize`, `OnFinalize`, `AfterFinalize`). Two helpers in one land can declare the same one. The land is then refused at registration, and the error names both places. Two `Lifetime` blocks that set different things combine, and so do `AllowedClientEvents` lists and `ServerEvents` registrations.

`@Land` declares a land as a type. Its `body` is under the builder and returns `LandRules`, like a helper:

```swift
@Land(GameState.self)
struct GameLand {
    static var body: LandRules<GameState, NoServices> {
        Rules {
            OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
        }
    }
}

let definition = GameLand.definition
```

`@Land(GameState.self)` makes a land without services. `@Land(GameState.self, services: AppServices.self)` makes one with services: its `definition` is a `TypedLand<GameState, AppServices>`, its `body` returns `LandRules<GameState, AppServices>`, and it is registered with `register(landType:land:services:…)` ([Resolver: Services](resolver.md#services)).

## LandContext

Handlers receive `LandContext`, containing:

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata` (from join/JWT/guest)
- `services` (injected external services)
- `emitEvent(...)`, `requestSyncNow()`, `requestSyncBroadcastOnly()`

LandContext is request-scoped, avoid saving references.

## Resolver

`HandleAction`, `CanJoin`, `OnJoin`, `OnLeave`, `OnInitialize` and `OnFinalize` can declare resolvers. They run in parallel before the handler, and the handler gets their outputs as parameters:

```swift
HandleAction(AddToCartAction.self, resolvers: { _, action, _ in ProductInfo(productID: action.productID) }) {
    state, action, product, ctx in
    ...
}
```

The `resolvers:` closure builds the resolver values from the State and the input, in the turn that admits the input. See [Resolver](resolver.md).

## Lifetime

- `Tick(every:)`: Game gameplay logic updates (can modify state)
- `StateSync(every:)`: State synchronization (read-only callback, will be called)
- `DestroyWhenEmpty(after:)`: Auto-close empty rooms
- `PersistSnapshot(every:)`: Snapshot period
- `OnInitialize` / `OnFinalize` / `AfterFinalize`. Like the input handlers, none of them throws after it writes (#593):
  - `OnFinalize` and the `DestroyWhenEmpty(after:_:)` handler take bodies that don't throw. The land is ending, so nothing would act on a refusal: a body that calls throwing code handles its errors itself.
  - `OnInitialize` takes a body that doesn't throw, or two stages, `validate` and `apply`, as an input does ([Two-Phase Handlers](#two-phase-handlers)). A `validate` that throws fails the land's initialization, as a failing resolver does, with nothing written (see the example below).
  - A re-evaluation (replay) keeper runs none of the destroy handlers: the record holds no finalize event, so replay has nothing to check them against.
  - The destroy handlers (`OnFinalize`, `AfterFinalize` and the `DestroyWhenEmpty(after:_:)` handler) have no outputs: an event they emit and a sync request they make are dropped. The land is ending, and no tick or sync runs again to send them. A server input they submit (`ctx.serverInputs.submit`) is refused as draining (`.refused(.draining)`). `ctx.random` works.
- `OnInitialize(resolvers:onResolverFailure:)`: a throwing resolver fails the land's initialization by default (`.failLand`); `.continue` runs OnInitialize without the resolvers' outputs. See [Resolver deadline](resolver.md#deadline)

```swift
Lifetime {
    // Game logic updates (20Hz)
    Tick(every: .milliseconds(50)) { state, ctx in
        // Use ctx.tickId (Int64) for deterministic, replay-compatible logic
        if let tickId = ctx.tickId {
            let tickIntervalSeconds = 0.05  // 50ms = 0.05s
            let gameTime = Double(tickId) * tickIntervalSeconds
            state.position += state.velocity * tickIntervalSeconds
        }
    }
    
    // Network synchronization (10Hz)
    // Callback is read-only and will be called during sync - do NOT modify state
    StateSync(every: .milliseconds(100)) { state, ctx in
        // Read-only callback - will be called during sync
        // Use for logging, metrics, or other read-only operations
        // Network sync mechanism triggers network synchronization after callback
    }
    // If StateSync is not set, it auto-configures to match tick interval
}
```

**Note**: `Tick` is the only source of state mutations for replay functionality. `StateSync` only triggers state synchronization and does not modify state. The optional callback is read-only and will be called during sync operations for logging, metrics, or other read-only operations.

### An Initialization That Can Be Refused

A land may need data it can't start without: a room's configuration, loaded by a resolver. `validate` checks that the data is there and returns it as the plan. `apply` writes it.

```swift
Lifetime {
    OnInitialize(
        resolvers: { _, ctx in RoomConfig(roomID: ctx.landID) },
        onResolverFailure: .continue,
        validate: { _, roomConfig, _ in
            guard let roomConfig else { throw RoomSetupError.noConfig }
            return roomConfig
        },
        apply: { state, _, config, _ in
            state.maxPlayers = config.maxPlayers
        }
    )
}
```

With `.continue`, a resolver that throws leaves `roomConfig` `nil`, and `validate` refuses. A refusal fails the initialization, as `.failLand` does for the resolver: the land is torn down without its destroy handlers, and a join that was waiting gets the retryable `JOIN_DENIED`. A retried join creates a new land.
