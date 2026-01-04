[English](index.en.md) | [中文版](index.md)

# Documentation Index

Welcome to the SwiftStateTree documentation center. This page provides complete documentation navigation and recommended reading order.

## 🚀 Quick Start

If this is your first time with SwiftStateTree, we recommend reading in the following order:

1. **[Overview](overview.en.md)** - Understand system architecture and core concepts
2. **[Architecture Overview](programming-model.en.md)** - Deep dive into StateTree's design philosophy and core concepts (optional but recommended)
3. **[Quick Start](quickstart.en.md)** - Implement a minimal viable example
4. **[Land DSL](core/land-dsl.en.md)** - Learn how to define domain logic
5. **[Sync Rules](core/sync.en.md)** - Understand state synchronization mechanisms

## 📚 Complete Documentation Directory

### Getting Started

- **[Overview](overview.en.md)** - System architecture, module composition, core concepts
- **[Architecture Overview](programming-model.en.md)** - Complete conceptual explanation of StateTree architecture (state layer, action layer, Resolver, semantic model, etc.)
- **[Architecture Layers](architecture.en.md)** - Component layered architecture and relationship descriptions
- **[Quick Start](quickstart.en.md)** - Build your first server from scratch

### Core Concepts

- **[Core Module](core/README.en.md)** - StateNode, Sync, Land DSL, Runtime overview
- **[Land DSL](core/land-dsl.en.md)** - Domain definition, AccessControl, Rules, Lifetime
- **[Sync Rules](core/sync.en.md)** - `@Sync` strategies, `@Internal`, sync engine

### Integration & Deployment

- **[Transport Layer](transport/README.en.md)** - WebSocket, connection management, multi-room support
- **[Hummingbird Integration](hummingbird/README.en.md)** - Server configuration, single-room/multi-room modes
- **[Authentication](hummingbird/auth.en.md)** - JWT, Guest mode, Admin routes

### Examples

- **[Cookie Clicker Example](examples/cookie-clicker.en.md)** - Complete multiplayer game example showcasing advanced features

### Reference Documentation

- **[Schema Generation](schema/README.en.md)** - JSON Schema auto-generation
- **[Macros](macros/README.en.md)** - `@StateNodeBuilder`, `@Payload`, `@SnapshotConvertible`

## 🔍 Find by Use Case

### I want to build a game server

1. [Quick Start](quickstart.en.md) - Basic setup
2. [Land DSL](core/land-dsl.en.md) - Define game logic
3. [Hummingbird Integration](hummingbird/README.en.md) - Deploy server

### I want to understand state synchronization

1. [Sync Rules](core/sync.en.md) - Sync strategy details
2. [Core Module](core/README.en.md) - Runtime and SyncEngine

### I want to implement multi-room architecture

1. [Architecture Layers](architecture.en.md) - Understand component layers and relationships
2. [Transport Layer](transport/README.en.md) - Multi-room management
3. [Hummingbird Integration](hummingbird/README.en.md) - Multi-room mode configuration

### I want to optimize performance

1. [Macros](macros/README.en.md) - Use `@SnapshotConvertible` to improve performance
2. [Core Module](core/README.en.md) - Understand Runtime operation mechanisms

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
