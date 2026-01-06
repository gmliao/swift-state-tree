[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land is the smallest runnable unit of server logic, responsible for defining join rules, behavior rules, and lifecycle.
`Land(...)` collects DSL nodes and generates `LandDefinition<State>`, executed by Runtime.

## Design Notes

- Land DSL only describes behavior, doesn't expose Transport details
- Handlers are defined synchronously, necessary async can be added via `ctx.spawn`
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

## LandContext

Handlers receive `LandContext`, containing:

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata` (from join/JWT/guest)
- `services` (injected external services)
- `sendEvent(...)`, `syncNow()`, `spawn { ... }`

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
