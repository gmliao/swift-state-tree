[English](README.md) | [中文版](README.zh-TW.md)

# TypeScript SDK Architecture

The SwiftStateTree TypeScript SDK provides a client-side library for connecting to and interacting with SwiftStateTree servers. This document explains the layered architecture and how different frameworks should integrate with the SDK.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Framework-Specific Layer                      │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  useHeroDefense │  │   Cocos Hook    │  │   Native JS     │  │
│  │   (Vue 3)       │  │   (Cocos)       │  │                 │  │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  │
│           │                    │                    │           │
├───────────┴────────────────────┴────────────────────┴───────────┤
│                     Generated Code Layer                         │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                  HeroDefenseStateTree                        │ │
│  │  - Type-safe state access                                    │ │
│  │  - Type-safe actions                                         │ │
│  │  - Type-safe events                                          │ │
│  │  - Type-safe Map subscriptions (players.onAdd/onRemove)      │ │
│  └──────────────────────────┬──────────────────────────────────┘ │
│                             │                                    │
├─────────────────────────────┴────────────────────────────────────┤
│                        SDK Core Layer                            │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    StateTreeView                             │ │
│  │  - WebSocket connection management                           │ │
│  │  - State synchronization (snapshots, patches)                │ │
│  │  - Low-level onPatch callback                                │ │
│  └──────────────────────────┬──────────────────────────────────┘ │
│                             │                                    │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                   StateTreeRuntime                           │ │
│  │  - Multi-land routing                                        │ │
│  │  - Message dispatching                                       │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Layer Responsibilities

### SDK Core Layer (`@swiftstatetree/sdk`)

The foundation layer providing:

- **StateTreeRuntime**: Manages WebSocket connections and routes messages to appropriate lands
- **StateTreeView**: Represents a view of a specific land's state tree
  - Handles state synchronization (snapshots, patches)
  - Provides low-level `onPatch()` callback for raw patch observation
  - Framework-agnostic, pure TypeScript

### Generated Code Layer (Codegen)

Type-safe wrappers generated from the server schema:

- **`{LandName}StateTree`**: The main entry point for applications
  - Wraps `StateTreeView` with type-safe interfaces
  - Provides `state`, `actions`, `events` accessors
  - Provides Map subscriptions (e.g., `players.onAdd()`, `players.onRemove()`)

Example:

```typescript
// Generated HeroDefenseStateTree
class HeroDefenseStateTree {
    readonly view: StateTreeView
    
    // Type-safe state access
    get state(): HeroDefenseState { ... }
    
    // Type-safe actions
    readonly actions = {
        moveTo(position: Position): void { ... },
        attack(targetId: string): void { ... }
    }
    
    // Type-safe events
    readonly events = {
        onDamageDealt(callback: (event: DamageDealtEvent) => void): () => void { ... }
    }
    
    // Type-safe Map subscriptions
    readonly players: MapSubscriptions<PlayerState>
}
```

### Framework-Specific Layer

Adapters that integrate the generated code with specific UI frameworks:

| Framework | Adapter | Reactivity |
|-----------|---------|------------|
| Vue 3 | `useHeroDefense()` | `ref()`, `reactive()`, `computed()` |
| React | `useHeroDefense()` | `useState()`, `useEffect()` |
| Cocos | Custom wrapper | Cocos signals/events |
| Phaser | Direct usage | Manual updates |
| Native JS | Direct usage | Callbacks |

## Usage Patterns

### Pattern 1: Vue 3 Components

Use the generated composable for reactive state:

```typescript
// In a Vue component
import { useHeroDefense } from './generated/hero-defense/useHeroDefense'

const { state, actions, events, currentPlayerID } = useHeroDefense(runtime, landID)

// state is reactive - template updates automatically
// actions are callable methods
// events provide subscription functions
```

### Pattern 2: Phaser/Game Engines (Framework-Agnostic)

Use `HeroDefenseStateTree` directly:

```typescript
// In a Phaser scene
import { HeroDefenseStateTree } from './generated/hero-defense'

class GameScene extends Phaser.Scene {
    private tree: HeroDefenseStateTree
    private playerManager: PlayerManager
    
    setStateTree(tree: HeroDefenseStateTree) {
        this.tree = tree
        
        // Subscribe to Map changes
        tree.players.onAdd((playerID, playerState) => {
            this.playerManager.createPlayer(playerID, playerState)
        })
        
        tree.players.onRemove((playerID) => {
            this.playerManager.removePlayer(playerID)
        })
    }
    
    update() {
        // Read state directly (non-reactive)
        const players = this.tree.state.players
        this.playerManager.updatePlayers(players)
    }
}
```

### Pattern 3: Low-Level Patch Observation

For advanced use cases, observe raw patches:

```typescript
const tree = new HeroDefenseStateTree(view)

// Low-level: observe all patches
tree.view.onPatch((patch, decodedValue) => {
    console.log(`${patch.op} at ${patch.path}:`, decodedValue)
})
```

## Map Subscriptions

The generated code provides type-safe subscriptions for Map properties:

```typescript
interface MapSubscriptions<T> {
    onAdd(callback: (key: string, value: T) => void): () => void
    onRemove(callback: (key: string) => void): () => void
}
```

These are automatically generated for any state property defined as a Map (object with dynamic keys):

```swift
// Server-side definition
@StateNodeBuilder
class HeroDefenseLand {
    var players: [String: PlayerState] = [:]  // Generates MapSubscriptions<PlayerState>
}
```

## Errors and Connection Loss

How each request settles:

| Situation | `view.join()` | `view.sendAction()` |
|---|---|---|
| Server answers | resolves `{ success: true, playerID, ... }` | resolves the response |
| Server refuses or reports an error | resolves `{ success: false, reason }` | rejects with an `Error` (`code`, `details` from the error frame) |
| Runtime not connected / view not joined | rejects (`Runtime not connected`) | rejects (`Not joined to land`) |
| The connection closes, `runtime.disconnect()`, or `runtime.removeView()` while waiting | rejects with `ConnectionClosedError` | rejects with `ConnectionClosedError` |

`ConnectionClosedError` (exported from `@swiftstatetree/sdk`) means no answer can arrive any more:

- `kind`: `'close'` (the WebSocket closed), `'disconnect'` (the client called `disconnect()`) or `'viewRemoved'`;
- `closeCode`, `closeReason`, `wasClean`: the WebSocket close details, when `kind` is `'close'`.

Every pending request settles exactly once: a response that arrives after the close is ignored. On close, the runtime destroys its views, so a view from before a reconnect is no longer joined and its `sendAction()` rejects; create and join a new view on the new connection. There is no per-request timeout yet; wrap a call in your own deadline if you need one.

```typescript
import { ConnectionClosedError } from '@swiftstatetree/sdk'

try {
  await view.sendAction('Move', payload)
} catch (error) {
  if (error instanceof ConnectionClosedError) {
    // reconnect, then create and join a new view
  } else {
    // the server rejected the action
  }
}
```

### Connecting and Reconnecting

- `connect(url)` while a connect to the same URL is in progress returns the same promise and opens no second socket; a connect to another URL is refused (`Already connecting to <url>`). Wait for it, or call `disconnect()` first.
- `disconnect()` during a connect aborts it: the connect rejects with `ConnectionClosedError` (`kind: 'disconnect'`), and a socket still being created is closed when it arrives.
- After `disconnect()`, the old socket's late events (open, message, error, close) are ignored, so `disconnect()` followed at once by `connect()` is safe; this is what a live/replay switch does.
- A connect while the current connection is still open (including one the server is closing) is refused with `Already connected`.
- `StateTreeSession` runs mode switches one at a time, in call order. `session.disconnect()` cancels the running switch and every queued one: each rejects with `ConnectionClosedError` (`kind: 'disconnect'`) and the mode stays as it was. The generated Vue composables do the same: `connect()` while one is in progress returns it, `disconnect()` stops a connect at its next await, and a close while joining rejects the connect and sets `lastError`.

### Delivery Semantics: At Most Once

An action is delivered at most once:

- **Pending actions are rejected on close, and their outcome is unknown.** A `ConnectionClosedError` means no answer can arrive. It does not say whether the server applied the action: it may have been applied before the close, or never received.
- **Nothing retries automatically.** The SDK never resends an action or a client event, and neither do the CLI and the load tester. A resend is the app's choice, and the server applies a resent action again.
- **firstSync is the truth.** After a reconnect, the state the new view receives in its firstSync is the server's complete view of the player. To learn whether an action took effect, read it from that state, not from the rejected promise. The rebuild is exact because the runtime destroys its views on every disconnect and close: the new view starts empty, so a player or field removed on the server while the client was away is simply not there (#219, checked end to end with convergence and a replay-verified recording).
- **On a tick land, an action's response is an ACK: "queued", not "applied".** The handler runs in a later tick, and its return value doesn't reach the client. Read the result from state.
- **At-most-once per operation needs an ID in the payload.** For an operation that must not happen twice (a purchase, for example), put an ID in the action's payload and have the land's handler record the IDs it has applied in land state, bounded by the app. The transport has no built-in deduplication, by design: dedup in state is deterministic and replayed with the land, and one outside it wouldn't be. See [Actions that must apply at most once](../core/land-dsl.md#actions-that-must-apply-at-most-once) for an example.

A `firstSync` update is not always a complete view. The server also types an update `firstSync` to reset a dynamic key scope on a live connection (for example when another player joins); its patches are then a normal diff. So a view applies a firstSync's patches onto its state like a diff and never clears it, and the runtime's dynamic key tables, cleared on every disconnect and close, are redefined by the frame as it is decoded.

A **resync** update is a complete view on a live connection. Every hosted land tracks sync lag (`syncSequence`, see [Sync lag and in-place resync](../transport/README.md#sync-lag-and-in-place-resync)) sends one when the client fell behind the frames it was sent. The view reconciles it with the state it has: it builds the new state, diffs it against the old one, and notifies only net changes (`onPatch` and the map subscriptions per change, then `onStateUpdate` once), then calls `onResync`. Nothing reconnects, and pending actions stay pending. With `syncSequence` negotiated, the runtime acks the last applied sequence (`[108, seq]`) every `ackIntervalMs` (default 1000), from the apply path once that interval has passed, and at once after a firstSync or a resync.

## Choosing the Right Layer

| Use Case | Recommended Layer |
|----------|-------------------|
| Vue/React UI components | Framework-specific (`useHeroDefense`) |
| Phaser/Cocos game scenes | Generated code (`HeroDefenseStateTree`) |
| Custom game engines | Generated code (`HeroDefenseStateTree`) |
| Debugging/logging | SDK Core (`StateTreeView.onPatch`) |
| Building new framework adapters | SDK Core + Generated code |

## Best Practices

1. **Don't mix layers unnecessarily**: If using Vue, use `useHeroDefense()`. If using Phaser, use `HeroDefenseStateTree` directly.

2. **Avoid re-wrapping**: The generated `StateTree` is already the framework-agnostic middle layer. Don't create additional wrapper interfaces.

3. **Use Map subscriptions for collections**: For player/entity management, prefer `onAdd`/`onRemove` over manual diffing.

4. **Keep game logic framework-agnostic**: Game managers (like `PlayerManager`) should depend on `HeroDefenseStateTree`, not Vue/React hooks.
