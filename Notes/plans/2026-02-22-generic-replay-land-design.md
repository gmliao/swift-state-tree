# Generic Replay Land Design

**Date:** 2026-02-22
**Status:** Approved

## Problem

`HeroDefenseReplayLand.swift` is ~300 lines of boilerplate that every new game must duplicate:
- Manual field-by-field JSON parsing in `applyProjectedState` (~120 lines)
- Hardcoded event whitelist (`projectedReplayAllowedEventTypes`)
- Game-specific `HeroDefenseReplayTickEvent` that is identical in structure to what any replay land needs
- The replay tick loop structure is the same for every game

## Goals

1. Zero-config: developers can delete their `*ReplayLand.swift` entirely
2. Extension point: developers who need custom actions (fast-forward, reset, etc.) can still assemble their own replay land with minimal boilerplate
3. Simple architecture: no wrapper state types, no code generation macros

## Non-Goals

- Supporting partial/diff-based state projection (full state snapshot is sufficient)
- Automatic event whitelisting (replay forwards all events by default)

## Design

### New Components (in `SwiftStateTreeReevaluationMonitor`)

#### `ReplayTickEvent`

Generic replacement for `HeroDefenseReplayTickEvent`. Identical fields, shared by all replay lands.

```swift
public struct ReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String
}
```

#### `StandardReplayBehavior<State>`

A DSL building block that encapsulates the standard replay tick loop. Conforms to the Land DSL result builder protocol so it can be embedded inside a `Land { ... }` block alongside custom `Lifetime` and `ServerEvents` sections.

Responsibilities:
- On idle: resolve record path from landID instanceId, call `service.startVerification`
- On result: decode projected state via `JSONDecoder().decode(State.self, ...)`, forward all server events without filtering, emit `ReplayTickEvent`
- Auto-registers `ReplayTickEvent` in `ServerEvents`
- On decode failure: log warning, skip tick (do not crash)

The `resolveReplayRecordPath` helper (currently in `HeroDefenseReplayLand.swift`) moves here as a private function.

```swift
public struct StandardReplayBehavior<State: StateNodeProtocol & Decodable> {
    public init(landType: String)
}
```

#### `GenericReplayLand`

Assembles `StandardReplayBehavior` into a complete zero-config `LandDefinition`.

```swift
public enum GenericReplayLand {
    public static func makeLand<State>(
        landType: String,
        stateType: State.Type
    ) -> LandDefinition<State>
    where State: StateNodeProtocol & Decodable
}
```

### Modified Components

#### `ReevaluationFeature.swift`

`registerWithReevaluationSameLand` adds `Decodable` constraint and uses `GenericReplayLand.makeLand()` instead of reusing the live land definition for replay.

```swift
// Before
func registerWithReevaluationSameLand<State: StateNodeProtocol>(...)

// After
func registerWithReevaluationSameLand<State: StateNodeProtocol & Decodable>(...)
// internally calls GenericReplayLand.makeLand(landType: replayLandType, stateType: State.self)
```

### Deleted Components

- `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift` — entire file deleted
- `HeroDefenseReplayTickEvent` — replaced by `ReplayTickEvent`

## Usage

### Zero-config (default)

```swift
try await host.registerWithReevaluationSameLand(
    landType: "hero-defense",
    liveLand: HeroDefenseLand.makeLand(),
    liveInitialState: HeroDefenseState(),
    liveWebSocketPath: "/ws/hero-defense",
    configuration: config,
    reevaluation: reevalConfig
)
// No ReplayLand file needed
```

### Custom actions (extension point)

```swift
Land("hero-defense-replay", using: HeroDefenseState.self) {
    AccessControl {
        AllowPublic(true)
        MaxPlayers(64)
    }

    StandardReplayBehavior<HeroDefenseState>(landType: "hero-defense")

    Lifetime {
        Action(FastForwardAction.self) { state, ctx, action in
            ctx.services.get(ReevaluationRunnerService.self)?.setSpeed(action.multiplier)
        }
    }

    ServerEvents {
        Register(FastForwardEvent.self)
        // ReplayTickEvent is auto-registered by StandardReplayBehavior
    }
}
```

## Data Flow

```
ReevaluationRunnerService.consumeNextResult()
    → result.projectedFrame?.stateObject  ([String: AnyCodable])
    → JSONSerialization.data(withJSONObject:)
    → JSONDecoder().decode(State.self, from:)
    → state = decodedState
    → emit all server events (no filtering)
    → emit ReplayTickEvent
    → ctx.requestSyncBroadcastOnly()
```

## Testing

- Unit: `StandardReplayBehavior` decode failure path (warning log, tick skipped, no crash)
- Unit: `GenericReplayLand.makeLand` produces a valid `LandDefinition`
- E2E: `registerWithReevaluationSameLand` replay flow, confirm state is applied correctly
