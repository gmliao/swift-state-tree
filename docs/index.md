[English](index.md) | [中文版](index.zh-TW.md)

# Documentation Index

Welcome to the SwiftStateTree documentation center. This page provides complete documentation navigation and recommended reading order.

## 🚀 Quick Start

If this is your first time with SwiftStateTree, we recommend reading in the following order:

1. **[Overview](overview.md)** - Understand system architecture and core concepts
2. **[Architecture Overview](programming-model.md)** - Deep dive into StateTree's design philosophy and core concepts (optional but recommended)
3. **[Quick Start](quickstart.md)** - Implement a minimal viable example
4. **[Land DSL](core/land-dsl.md)** - Learn how to define domain logic
5. **[Sync Rules](core/sync.md)** - Understand state synchronization mechanisms

## 📚 Complete Documentation Directory

### Getting Started

- **[Overview](overview.md)** - System architecture, module composition, core concepts
- **[Architecture Overview](programming-model.md)** - Complete conceptual explanation of StateTree architecture (state layer, action layer, Resolver, semantic model, etc.)
- **[Architecture Layers](architecture.md)** - Component layered architecture and relationship descriptions
- **[Quick Start](quickstart.md)** - Build your first server from scratch

### Core Concepts

- **[Core Module](core/README.md)** - StateNode, Sync, Land DSL, Runtime overview
- **[Land DSL](core/land-dsl.md)** - Domain definition, AccessControl, Rules, Lifetime
- **[Sync Rules](core/sync.md)** - `@Sync` strategies, `@Internal`, sync engine

### Integration & Deployment

- **[Transport Layer](transport/README.md)** - WebSocket, connection management, multi-room support
- **[Transport Evolution](transport_evolution.md)** - Evolution history from JSON to MessagePack binary encoding
- **[Hummingbird Integration](hummingbird/README.md)** - Server configuration, single-room/multi-room modes
- **[Authentication](hummingbird/auth.md)** - JWT, Guest mode, Admin routes

### Examples

- **[Cookie Clicker Example](examples/cookie-clicker.md)** - Complete multiplayer game example showcasing advanced features

### Game Development

- **[Deterministic Math](deterministic-math/README.md)** - Fixed-point arithmetic, collision detection, and vector operations for server-authoritative games

### AI-Assisted Development

- **[AI-Agent Architecture Observations](ai-agent-architecture-observations.md)** - Personal observations and research context for ECS-inspired systems and AI workflows

### Client SDK

- **[TypeScript SDK](sdk/README.md)** - Client SDK architecture, layers, and framework integration

### Reference Documentation

- **[Schema Generation](schema/README.md)** - JSON Schema auto-generation
- **[Macros](macros/README.md)** - `@StateNodeBuilder`, `@Payload`, `@SnapshotConvertible`

## 🔍 Find by Use Case

### I want to build a game server

1. [Quick Start](quickstart.md) - Basic setup
2. [Land DSL](core/land-dsl.md) - Define game logic
3. [Hummingbird Integration](hummingbird/README.md) - Deploy server

### I want to understand state synchronization

1. [Sync Rules](core/sync.md) - Sync strategy details
2. [Core Module](core/README.md) - Runtime and SyncEngine

### I want to implement multi-room architecture

1. [Architecture Layers](architecture.md) - Understand component layers and relationships
2. [Transport Layer](transport/README.md) - Multi-room management
3. [Hummingbird Integration](hummingbird/README.md) - Multi-room mode configuration

### I want to optimize performance

1. [Macros](macros/README.md) - Use `@SnapshotConvertible` to improve performance
2. [Core Module](core/README.md) - Understand Runtime operation mechanisms
3. [Transport Evolution](transport_evolution.md) - Understand transport layer encoding optimizations

### I want to build a deterministic game

1. [Deterministic Math](deterministic-math/README.md) - Fixed-point math and collision detection
2. [Core Module](core/README.md) - StateNode and sync mechanisms

## 📝 Design & Development Notes

For detailed design documents and development notes, please refer to the [Notes/](../Notes/index.md) directory:

- `Notes/design/` - System design documents
- `Notes/guides/` - Development guides
- `Notes/performance/` - Performance analysis
- `Notes/protocol/` - Communication protocol specifications

## 💡 Documentation Structure

- **`docs/`** - Official published documentation, suitable for external reading
- **`Notes/`** - Internal design and development notes, may contain incomplete content

---

If you have questions or suggestions, please submit an [Issue](https://github.com/your-username/SwiftStateTree/issues).
