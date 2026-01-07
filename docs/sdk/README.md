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
