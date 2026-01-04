[English](land-dsl.en.md) | [中文版](land-dsl.md)

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

- `Tick(every:)`: Fixed frequency tick
- `DestroyWhenEmpty(after:)`: Auto-close empty rooms
- `PersistSnapshot(every:)`: Snapshot period
- `OnInitialize` / `OnFinalize` / `AfterFinalize` / `OnShutdown`

```swift
Lifetime {
    Tick(every: .seconds(1)) { state, ctx in
        // periodic logic
    }
}
```
