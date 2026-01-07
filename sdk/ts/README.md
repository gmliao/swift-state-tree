# SwiftStateTree TypeScript SDK

Client-side SDK for connecting to SwiftStateTree servers.

## Installation

```bash
npm install @swiftstatetree/sdk
```

## Quick Start

```typescript
import { StateTreeRuntime } from '@swiftstatetree/sdk'

// Create runtime and connect
const runtime = new StateTreeRuntime()
await runtime.connect('ws://localhost:8080/ws')

// Join a land
const view = await runtime.join('hero-defense', 'room-1')

// Access state
console.log(view.state)

// Send actions
view.send({ type: 'moveTo', payload: { x: 100, y: 200 } })
```

## Architecture

See the [SDK Architecture Documentation](../../docs/sdk/README.md) for details on:

- Layer responsibilities (Core, Generated, Framework-specific)
- Usage patterns for different frameworks (Vue, React, Phaser, etc.)
- Map subscriptions and patch observation
- Best practices

## Code Generation

Generate type-safe client code from server schema:

```bash
npx swiftstatetree-codegen --schema schema.json --output src/generated
```

This generates:
- Type definitions for state, actions, and events
- `{LandName}StateTree` class with type-safe APIs
- `use{LandName}` Vue composable (optional)

## Development

```bash
# Install dependencies
npm install

# Build
npm run build

# Run tests
npm test
```

## License

MIT
