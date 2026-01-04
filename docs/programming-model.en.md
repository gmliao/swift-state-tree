[English](programming-model.en.md) | [中文版](programming-model.md)

# StateTree: A Reactive Server State Programming Model

> **About this document**: This document organizes and defines a reactive server state programming model named **StateTree**. This model was developed by the author through practical development and architectural design, used to describe a server-side state management and synchronization approach centered on a "single authoritative state tree."
>
> This document describes a **programming model (semantic model)**, not a specific framework or language implementation; the Swift implementation mentioned in this document is only for reference and is not the only or necessary way to implement this model. To avoid semantic confusion, the definitions of State / Action / Resolver in this document take precedence.

StateTree is a reactive server state programming model based on a **State Machine Core**. This architecture clearly separates "State", "Action", and "Data Source (Resolver)", providing a clear server-side state management model.

> This programming model was primarily developed based on Vue's reactive pattern and backend data filtering practices, evolving into a server-side reactive state management model. By expressing server state through a state tree, data can be synchronized to clients in a reactive manner, achieving automated state synchronization and updates. During the organization process, it was also discovered that certain design concepts are similar to Redux's single state tree concept.

The current implementation uses a **room-based** real-time mode (Active StateTree), where state persists and is synchronized to clients via WebSocket.

This document will describe its core semantic model and design philosophy from a complete architectural perspective, and at the end, infer the characteristics of this model based on the design content.

---

## 1. State Layer (State Layer) —— StateTree = Single Source of Truth

StateTree represents the "true state" on the server side, organizing state data in a tree structure.

**Core Characteristics**:

* **Value type, Snapshot-based**: State is a value type and can generate snapshots
* **Immutability principle**: State cannot be directly modified externally
* **Sync strategy marking**: Each state property needs to be marked with a sync strategy (which data syncs to which clients)
* **Single modification entry**: State can only be modified through Actions
* **Automatic sync mechanism**: All modifications automatically generate diffs and sync to clients

The complete evolution trajectory of state is controlled only by Actions, making StateTree highly inferable.

---

## 2. Action Layer (Action Layer) —— The Only Entry Point for Modifying State

Action is the only place that can modify StateTree.

**Core Design**:

* **Single modification entry**: All state changes must go through Action handlers
* **Synchronous execution**: Action handlers themselves are synchronous and do not contain async operations
* **Input and output**: Action handlers receive current state, Action payload, and context provided by Resolver, returning a Response
* **State modification method**: Modify state through pass by reference

**Design Recommendation: Deterministic Action (currently not enforced)**

Although the current implementation does not enforce it, it is recommended that Action handlers remain deterministic:

* Avoid calling non-deterministic APIs like random/time/uuid (or use seeds)
* Action dependencies:
  * Current State
  * Action Payload
  * Context provided by Resolver
* Same input → produces same output

This makes StateTree more inferable and has great advantages for debugging, replay, synchronization, and replication.

Action's responsibility is very simple:

> **According to business logic, decide which data to write into StateTree.**

Resolver only provides auxiliary information (reference data) and cannot directly write to StateTree.

---

## 3. Data Source Layer (Resolver Layer) —— Context Provider for Actions

Resolver is one of the core innovations of the StateTree architecture.

Resolver's positioning is as follows:

* Provides "external source data" needed by Action/Event handlers
* Can only read external systems, cannot modify StateTree
* **Parallel execution**: All declared resolvers execute in parallel before handler execution
* **Fill context after execution**: Resolver results fill the handler's context
* **Not in state tree**: Resolver output data does not enter StateTree and is not synchronized or persisted

Resolver's essential role:

> **Provides context needed by Action/Event handlers (Context Provider), not part of state.**

Difference between StateNode vs ResolverOutput:

| Category | Source | Enters StateTree? | Can change sync behavior? |
|------|------|----------------|----------------|
| **StateNode** | server state | ✔ | ✔ (can define sync strategy) |
| **ResolverOutput** | external data source | ✘ | ✘ |

---

## 4. Semantic Layer (Semantic Model) —— Core Concept Integration of StateTree

The following is the semantic foundation for StateTree to become a "complete reactive server architecture."

---

### 4.1 Resolver Execution Mode

Resolver uses **eager parallel execution** mode:

* Before Action/Event handler execution, all declared resolvers execute in parallel
* After Resolver execution completes, results fill the handler's context
* Handler can synchronously access resolver results
* Handler itself is synchronous and does not need to handle async operations

**Parallel Execution Advantages**:

* Multiple resolvers execute simultaneously, reducing total execution time
* Handler remains synchronous, logic is clearer
* Unified error handling: Any resolver failure aborts the entire processing flow

---

### 4.2 Data Ownership Rules for Resolver and State

* **Data needed for sync** → Must be written into StateTree
* **Data needed by Action but not for sync** → Place in ResolverOutput
* **Large, frequently changing data (like stocks)** → Should not enter Tree (would explode diff), supply via Resolver
* **Persistent or logical core data** → Always enter Tree (needs sync)

ResolverOutput is context, StateNode is authoritative state. The relationship between the two cannot be confused.

---

## 5. Runtime Layer——StateTree Execution Flow

Complete flow is as follows:

```
Client → Action(payload)
           |
           v
   [Create Context]
           |
           v
   [Parallel Execute Resolvers]
       • All declared resolvers execute in parallel
       • Load external data (DB, API, etc.)
       • Results fill context
           |
           v
   [Action Handler Execution]
       • Read state
       • Read payload
       • Read resolver results (synchronous access)
       • Modify state
       • Return Response
           |
           v
       [StateTree Updated → diff]
           |
           v
        [Sync Engine]
           |
           v
       Relevant Clients automatically receive updates
```

This flow ensures state changes are automatically synchronized to all relevant clients, achieving reactive server state management.

---

## 6. Future Extension Directions

### 6.1 Replay-Friendly Design

StateTree's design makes it replay-capable:

**Design Philosophy**:

Since Action handlers are recommended to remain deterministic (same input produces same output), StateTree can:

* Record complete trajectory of state changes
* Reconstruct state at any point in time through Action sequences
* Support state replay and debugging
* Future implementation of state-based logging systems

**Future Plans**:

* Add state-based logging system, recording state snapshots and Action sequences
* Support state replay functionality, can re-execute Action sequences from any snapshot point
* Implement complete debugging and auditing capabilities

**Note**: Logging system and replay functionality are currently not implemented and are future planning directions.

### 6.2 Passive StateTree (Stateless API Mode)

StateTree architecture can theoretically also support passive mode:

1. Each request creates a temporary Tree
2. Initialize data through Resolver
3. Execute one or more Actions
4. Return result
5. Discard Tree (server remains stateless)

**Note**: This functionality is currently not implemented and is a future planning direction. Currently all StateTrees are Active mode (room mode, state persists).

---

## 7. Design Characteristics Inference

Based on the aforementioned design content, the core design attributes and constraints of the StateTree programming model are as follows:

### Core Design Attributes/Constraints

1. **Single State Tree (Single Source of Truth)**: All state is concentrated in StateTree, no scattered state sources
2. **Action as the only modification entry**: State can only be modified through Action handlers, no other modification paths
3. **State is serializable**: State can be saved and restored in snapshot form
4. **Sync strategy separation**: Sync logic (which data syncs to whom) is separated from business logic (how to modify state)
5. **Resolver parallel execution**: Multiple Resolvers can load data in parallel before handler execution
6. **Recommended deterministic Action**: Action handlers are recommended to remain deterministic (same input produces same output)

### Characteristics Inferred from Design Attributes/Constraints

| Design Attributes/Constraints | → | Inferred Characteristics |
|-------------|---|------------|
| Single state tree<br/>+ Action as the only modification entry<br/>+ Recommended deterministic Action | → | **Determinism**<br/><br/>Because of single state tree, state source is clear, no ambiguity from scattered state; because Action is the only modification entry, change path is single and easy to track; because recommended deterministic Action, state evolution process is predictable. Therefore has determinism. |
| Action as the only modification entry<br/>+ State is serializable<br/>+ Recommended deterministic Action | → | **Verifiability**<br/><br/>Because Action is the only modification entry, all state changes have clear sources, change trajectory is complete; because state is serializable, state can be saved in snapshot form, convenient for verification and testing; because recommended deterministic Action, state changes are reproducible. Therefore has verifiability. |
| Single state tree<br/>+ Sync strategy separation | → | **Sync-friendly**<br/><br/>Because of single state tree, StateTree is the only source of truth, sync logic is clear, no need to coordinate multiple state sources; because sync strategy is separated, can clearly define which data syncs to which clients, sync behavior is configurable. Therefore has sync-friendliness. |
| Resolver parallel execution<br/>+ State is serializable<br/>+ Single state tree + Action unique modification entry | → | **High Parallelism**<br/><br/>Because Resolver executes in parallel, multiple Resolvers can load data simultaneously, reducing total execution time; because state is serializable, sync can be done in snapshot mode, not blocking state changes; because single state tree + Action unique modification entry, different rooms' StateTrees can execute in parallel (room isolation). Therefore has high parallelism. |
| Single state tree + Action unique modification entry<br/>+ Sync strategy separation<br/>+ State/Action/Resolver clear layering | → | **High Maintainability**<br/><br/>Because single state tree + Action unique modification entry, state changes are centralized and path is clear, easy to understand; because sync strategy is separated, sync logic and business logic are decoupled, responsibilities are clear; because State/Action/Resolver are clearly layered, each layer's responsibilities are clear, structure is clear. Therefore has high maintainability. |

---

## 8. Architecture Core Summary (The Five Most Important Sentences)

1. **Resolver provides data, not state.**
2. **Action handler decides which data to write into StateTree.**
3. **StateTree is the only source of truth, all sync comes from it.**
4. **Resolver executes in parallel before handler execution, handler synchronously accesses results.**
5. **Action handlers are recommended to remain deterministic, beneficial for debugging, replay, and future extensions.**

---

## Appendix: Swift Implementation Reference

> The following sections explain how to implement StateTree programming model concepts in Swift, for Swift developers' reference. The conceptual parts (above sections) are language-agnostic and can be read independently.

### A.1 Swift Implementation of StateNode

State in StateTree is implemented in Swift as a `struct` type implementing `StateNodeProtocol`, marked with `@StateNodeBuilder` macro:

* `StateNodeProtocol`: Protocol defining state nodes
* `@StateNodeBuilder` macro: Generates necessary sync metadata at compile time
* `@Sync`: Marks sync strategy (such as `.broadcast`, `.perPlayer`, etc.)
* `@Internal`: Marks internal use, non-synced fields

State is modified through `inout` parameters in Action handlers.

### A.2 Swift Implementation of Action Handler

Action handler signature in Swift is:

```swift
(inout State, ActionPayload, LandContext) throws -> Response
```

* Action handlers execute in `LandKeeper` actor's isolated context
* Handler is synchronous, but Resolver completes in parallel before execution
* State is directly modified through `inout` parameters

### A.3 Swift Implementation of Resolver

Resolver is implemented in Swift as a type implementing `ContextResolver` protocol:

* Resolver output must implement `ResolverOutput` protocol
* Access resolver results in handler through `LandContext`'s `@dynamicMemberLookup` feature
* Resolver executes in parallel before handler execution

**Usage Example**:

```swift
Rules {
    HandleAction(UpdateCartAction.self, resolvers: (ProductInfoResolver.self, UserBalanceResolver.self)) { state, action, ctx in
        // Resolver has already executed in parallel, results can be used directly
        let productInfo = ctx.productInfo  // ProductInfo?
        let userBalance = ctx.userBalance  // UserBalance?
        // ...
    }
}
```

### A.4 Swift Implementation of Runtime

* `LandKeeper`: Acts as actor, manages state and executes handlers
* `LandContext`: Provides context information needed by handlers
* `SyncEngine`: Responsible for generating state snapshots and diffs, implementing sync mechanism

---

**For complete Swift implementation documentation, please refer to**:
- [Land DSL Guide](core/land-dsl.en.md)
- [Sync Rules Details](core/sync.en.md)
- [Runtime Operation Mechanism](core/runtime.en.md)
- [Resolver Usage Guide](core/resolver.en.md)
