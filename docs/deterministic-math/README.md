[English](README.md) | [中文版](README.zh-TW.md)

# Deterministic Math

The `SwiftStateTreeDeterministicMath` module provides deterministic integer-based math operations for server-authoritative games. All operations use Int32 fixed-point arithmetic to ensure consistent behavior across platforms and replays.

## Overview

This module is designed for games that require:
- **Deterministic calculations** - Same inputs produce same outputs across platforms
- **Replay support** - Game state can be replayed exactly as it occurred
- **Server authority** - Server controls all game logic, clients interpolate
- **Performance** - SIMD-optimized vector operations for high-performance collision detection

## Core Components

### Fixed-Point Arithmetic

- **`FixedPoint`** - Centralized fixed-point conversion utilities
  - Scale factor: 1000 (1.0 Float = 1000 Int32)
  - `quantize()` - Convert Float to Int32
  - `dequantize()` - Convert Int32 to Float

### Vector Types

- **`IVec2`** - 2D integer vector with SIMD optimization
  - Arithmetic operations (+, -, *)
  - Dot product, cross product
  - Distance calculations
  - Angle conversions
  - Reflection and projection

- **`IVec3`** - 3D integer vector with SIMD optimization
  - Similar operations to IVec2, extended to 3D

### Semantic Types

Type-safe wrappers to prevent misuse:
- **`Position2`** - Position in 2D space
- **`Velocity2`** - Velocity vector
- **`Acceleration2`** - Acceleration vector

### Collision Detection

Complete 2D collision detection suite:
- **`IAABB2`** - Axis-aligned bounding box
  - Point containment
  - Box intersection
  - Clamping, expansion, union

- **`ICircle`** - Circle collision
  - Circle-circle intersection
  - Circle-AABB intersection
  - Point containment

- **`IRay`** - Raycast for bullet detection
  - Ray-AABB intersection
  - Ray-circle intersection

- **`ILineSegment`** - Line segment operations
  - Point-to-segment distance
  - Segment-segment intersection
  - Segment-circle intersection

### Grid Utilities

- **`Grid2`** - Grid-based coordinate conversions
  - World-to-cell conversion
  - Cell-to-world conversion
  - Snap to grid

### Overflow Handling

- **`OverflowPolicy`** - Centralized overflow behavior
  - Wrapping, clamping, trapping

## Usage Example

```swift
import SwiftStateTreeDeterministicMath

// Create a position using Float (more intuitive)
let playerPos = Position2(x: 1.5, y: 2.3)

// Create a velocity
let velocity = Velocity2(x: 0.1, y: 0.05)

// Update position (deterministic integer math)
let newPos = Position2(v: playerPos.v + velocity.v)

// Collision detection
let circle = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
let box = IAABB2(min: IVec2(x: -1.0, y: -1.0), max: IVec2(x: 1.0, y: 1.0))

if circle.intersects(aabb: box) {
    // Handle collision
}

// Raycast for bullet detection
let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), direction: IVec2(x: 1.0, y: 0.0))
if let (hitPoint, distance) = ray.intersects(aabb: box) {
    // Bullet hit the box at hitPoint
}
```

## Client-Side Integration

### Automatic Conversion

The TypeScript SDK automatically converts fixed-point integers to floats on the client side:

```typescript
// Server sends: { x: 1500, y: 2300 }
// Client receives: { x: 1.5, y: 2.3 } (automatically converted)

const pos = game.state.playerPositions['player1']
// pos.v.x and pos.v.y are already floats, ready to use
```

### Manual Conversion Helpers

Conversion helpers are also available if needed:

```typescript
import { IVec2ToFloat, FloatToIVec2 } from './generated/defs'

const vec: IVec2 = { x: 1500, y: 2300 }
const float = IVec2ToFloat(vec)  // { x: 1.5, y: 2.3 }
```

## Performance

All vector operations use SIMD (Single Instruction, Multiple Data) acceleration:
- Vector addition/subtraction: Parallel SIMD operations
- Dot product: SIMD parallel multiplication
- Distance calculations: SIMD parallel squaring
- All operations marked with `@inlinable` for compiler optimization

## Determinism Rules

For detailed rules on maintaining determinism, see [Determinism Rules](../../Sources/SwiftStateTreeDeterministicMath/Docs/DeterminismRules.md).

Key principles:
- ✅ Use integer arithmetic only
- ✅ Fixed-point quantization for Float values
- ❌ No Float arithmetic in tick logic
- ❌ No platform-specific math libraries

## Schema Generation

All DeterministicMath types are automatically included in schema generation:
- Types are exported to JSON Schema
- TypeScript codegen generates corresponding types
- Client-side conversion helpers are auto-generated

## Testing

All types have comprehensive unit tests in `SwiftStateTreeDeterministicMathTests`:
- Fixed-point conversion tests
- Vector operation tests
- Collision detection tests
- Integration tests with StateNode

Run tests with:
```bash
swift test --filter SwiftStateTreeDeterministicMathTests
```
