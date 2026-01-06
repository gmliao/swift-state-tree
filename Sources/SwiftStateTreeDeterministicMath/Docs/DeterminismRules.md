# Deterministic Math Rules

This document defines the rules and best practices for using deterministic math in server-authoritative games.

## Core Principles

### Server Authority

- **All authoritative game state must use integer math (Int32)**
- Server tick logic must be deterministic and platform-independent
- JSON serialization only stores Int32 values (never Float)

### Fixed-Point Representation

- **Scale factor**: 1000 (1.0 Float = 1000 Int32)
- All Float values must be quantized to Int32 before storage
- Use `FixedPoint.quantize()` and `FixedPoint.dequantize()` for conversions

## Server Tick Rules

### ✅ Allowed Operations

- Integer arithmetic: `+`, `-`, `*` (using `&+`, `&-`, `&*` for wrapping overflow)
- Fixed-point quantization/dequantization
- Deterministic integer comparisons
- Fixed-order iteration (sorted keys, deterministic order)

### ❌ Forbidden Operations

- **Float arithmetic in tick logic** (except for quantization/dequantization)
- **Square root (`sqrt`) or other floating-point functions**
- **Delta-time (`dt`) based calculations** (use fixed tick rate instead)
- **Non-deterministic iteration order** (e.g., Dictionary iteration without sorting)
- **Platform-specific math libraries** (use only standard library integer operations)
- **Random number generation** (unless using deterministic seed)

## JSON Serialization

### Format

All authoritative state must be serialized as Int32:

```swift
// ✅ Correct: Int32 in JSON
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var playerPosition: IVec2 = IVec2(x: 1000, y: 2000)
    // JSON: { "x": 1000, "y": 2000 }
}

// ❌ Wrong: Float in JSON
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var playerPosition: (x: Float, y: Float) = (1.0, 2.0)
    // JSON: { "x": 1.0, "y": 2.0 }  // Not deterministic!
}
```

## Client-Side Interpolation

### Rules

- **Clients can use Float for rendering and interpolation**
- **Clients must NOT write Float values back to server state**
- **Clients must quantize values before sending to server**

### Example: TypeScript + PhaserJS

```typescript
// From server state (auto-generated types)
const pos: { x: number; y: number } = state.playerPositions[playerId]

// Convert to PhaserJS format (client-side only)
const phaserPos = new Phaser.Math.Vector2(
  pos.x / 1000,  // Dequantize (scale = 1000)
  pos.y / 1000
)

// Use PhaserJS math for rendering/interpolation
const interpolatedPos = Phaser.Math.Vector2.Lerp(
  phaserPos,
  targetPhaserPos,
  alpha
)

// If sending back to server, must quantize
const serverPos = {
  x: Math.round(interpolatedPos.x * 1000),
  y: Math.round(interpolatedPos.y * 1000)
}
```

### Example: Swift Client (if needed)

```swift
// From server state
let pos: IVec2 = state.playerPositions[playerId]

// Convert to Float for rendering (client-side only)
let floatPos = CGPoint(
    x: CGFloat(pos.floatX),
    y: CGFloat(pos.floatY)
)

// Use Float for interpolation
let interpolated = lerp(start: floatPos, end: targetPos, alpha: alpha)

// If sending back to server, must quantize
let serverPos = IVec2(
    x: Float(interpolated.x),
    y: Float(interpolated.y)
)
```

## Overflow Behavior

### Wrapping Overflow (Default)

All arithmetic operations use **wrapping overflow** (`&+`, `&-`, `&*`) to ensure deterministic behavior:

```swift
let v1 = IVec2(x: Int32.max, y: 0)
let v2 = IVec2(x: 1, y: 0)
let sum = v1 + v2  // Wraps to Int32.min (deterministic)
```

This is the default behavior for all operators (`+`, `-`, `*`) to ensure determinism.

### Safe Operations (Prevent Overflow)

For operations that might overflow (especially multiplication and squaring), use safe versions that use Int64 intermediate values:

```swift
// Regular multiplication (wrapping overflow)
let v1 = IVec2(x: 2000000, y: 2000000)
let scaled1 = v1 * 2  // May wrap

// Safe multiplication (clamps to Int32 range)
let scaled2 = IVec2.multiplySafe(v1, by: 2)  // Clamps instead of wrapping
```

**When to use safe operations**:
- When multiplying large values that might exceed Int32 range
- When you need clamping behavior instead of wrapping
- For critical calculations where overflow would cause incorrect results

**Note**: Safe operations are slightly slower due to Int64 intermediate calculations, but prevent unexpected overflow.

### Range Considerations

- **Maximum representable value**: `Int32.max / 1000 ≈ 2,147,483.647`
- **Minimum representable value**: `Int32.min / 1000 ≈ -2,147,483.648`
- Use `FixedPoint.clampToInt32Range()` if values might exceed this range
- Use `multiplySafe(_:by:)` for multiplication operations that might overflow

### Operations Already Using Int64

The following operations already use Int64 internally to prevent overflow:
- `dot(_:)` - Dot product
- `magnitudeSquared()` - Squared magnitude
- `distanceSquared(to:)` - Squared distance
- `cross(_:)` (IVec3) - Cross product

These operations are safe to use with large values without risk of intermediate overflow.

## Testing Determinism

### Replay Testing

1. Record all inputs and initial state
2. Run simulation multiple times
3. Verify final state is identical across runs

### Cross-Platform Testing

1. Test on different architectures (x86_64, arm64)
2. Verify JSON serialization/deserialization produces identical results
3. Ensure no platform-specific floating-point differences

## Performance Optimizations

### SIMD Support

Vector operations use SIMD2<Int32> for optimized performance on macOS and Linux:

```swift
// Uses SIMD2<Int32> for optimized performance
let v1 = IVec2(x: 1000, y: 2000)
let v2 = IVec2(x: 500, y: 300)
let sum = v1 + v2  // Uses SIMD2<Int32> internally
```

**Benefits**:
- Vector operations are optimized using SIMD instructions
- Single instruction processes both x and y components simultaneously
- Maintains deterministic wrapping behavior

**Note**: SIMD operations maintain the same deterministic wrapping behavior as regular operations.

## Best Practices

1. **Always use IVec2/IVec3 for positions and velocities in server state**
2. **Use semantic types (Position2, Velocity2) for better type safety**
3. **Quantize immediately when receiving Float input**
4. **Dequantize only for display/interpolation (never for game logic)**
5. **Test with extreme values to catch overflow issues early**
6. **Use safe operations (`multiplySafe`) when overflow is a concern**
7. **Prefer `magnitudeSquared()` over `magnitude()` for comparisons (deterministic)**
8. **Document any deviations from these rules**

## Migration Guide

### Converting Existing Float-Based Code

1. Identify all Float values in server state
2. Replace with IVec2/IVec3 or semantic types
3. Add quantization at input boundaries
4. Update client code to dequantize for rendering
5. Test thoroughly with replay system

### Example Migration

```swift
// Before (non-deterministic)
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var playerX: Float = 0.0
    var playerY: Float = 0.0
}

// After (deterministic)
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var playerPosition: Position2 = Position2(v: .zero)
}
```
