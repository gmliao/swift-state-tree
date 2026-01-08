// Sources/SwiftStateTreeDeterministicMath/Core/IVec2.swift
//
// Integer 2D vector for deterministic server-authoritative game logic.
// All operations are deterministic and use Int32 to ensure consistency across platforms.

import Foundation
import SwiftStateTree

/// A 2D vector using Int32 coordinates for deterministic math.
///
/// This type is designed for server-authoritative game logic where determinism
/// is critical for replay and synchronization. All operations use integer arithmetic
/// to ensure consistent behavior across different platforms and architectures.
///
/// Example:
/// ```swift
/// let v1 = IVec2(x: 1000, y: 2000)
/// let v2 = IVec2(x: 500, y: 300)
/// let sum = v1 + v2  // IVec2(x: 1500, y: 2300)
/// ```
public struct IVec2: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The x coordinate.
    public let x: Int32
    
    /// The y coordinate.
    public let y: Int32
    
    // MARK: - Codable Implementation
    
    // Codable is automatically synthesized since x and y are stored properties
    
    /// Creates a new IVec2 from Float coordinates.
    ///
    /// This is the recommended way to create IVec2 instances, as it automatically
    /// quantizes Float values to fixed-point integers using the configured scale.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as Float (will be quantized).
    ///   - y: The y coordinate as Float (will be quantized).
    ///   - rounding: The rounding rule to apply (default: `.toNearestOrAwayFromZero`).
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 1.5, y: 2.3)  // Quantized to (1500, 2300) with scale 1000
    /// ```
    public init(
        x: Float,
        y: Float,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) {
        self.x = FixedPoint.quantize(x, rounding: rounding)
        self.y = FixedPoint.quantize(y, rounding: rounding)
    }
    
    /// Internal initializer for fixed-point integer coordinates.
    ///
    /// This is used internally for operations that already produce quantized values.
    /// External code should use `init(x:y:)` with Float values instead.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as fixed-point Int32.
    ///   - y: The y coordinate as fixed-point Int32.
    @inlinable
    internal init(fixedPointX x: Int32, fixedPointY y: Int32) {
        self.x = x
        self.y = y
    }
    
    /// The x coordinate as Float (dequantized).
    public var floatX: Float {
        FixedPoint.dequantize(x)
    }
    
    /// The y coordinate as Float (dequantized).
    public var floatY: Float {
        FixedPoint.dequantize(y)
    }
    
    /// The zero vector.
    public static let zero = IVec2(fixedPointX: 0, fixedPointY: 0)
}

// MARK: - Arithmetic Operations

extension IVec2 {
    /// Adds two vectors.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side vector.
    ///   - rhs: The right-hand side vector.
    /// - Returns: The sum of the two vectors.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    @inlinable
    public static func + (lhs: IVec2, rhs: IVec2) -> IVec2 {
        IVec2(fixedPointX: lhs.x &+ rhs.x, fixedPointY: lhs.y &+ rhs.y)
    }
    
    /// Subtracts two vectors.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side vector.
    ///   - rhs: The right-hand side vector.
    /// - Returns: The difference of the two vectors.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    @inlinable
    public static func - (lhs: IVec2, rhs: IVec2) -> IVec2 {
        IVec2(fixedPointX: lhs.x &- rhs.x, fixedPointY: lhs.y &- rhs.y)
    }
    
    /// Multiplies a vector by a scalar.
    ///
    /// - Parameters:
    ///   - lhs: The vector.
    ///   - scalar: The scalar value.
    /// - Returns: The scaled vector.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    /// For safe multiplication that prevents overflow, use `multiplySafe(_:by:)`.
    @inlinable
    public static func * (lhs: IVec2, scalar: Int32) -> IVec2 {
        IVec2(fixedPointX: lhs.x &* scalar, fixedPointY: lhs.y &* scalar)
    }
    
    /// Multiplies a scalar by a vector.
    ///
    /// - Parameters:
    ///   - scalar: The scalar value.
    ///   - rhs: The vector.
    /// - Returns: The scaled vector.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    /// For safe multiplication that prevents overflow, use `multiplySafe(_:by:)`.
    @inlinable
    public static func * (scalar: Int32, rhs: IVec2) -> IVec2 {
        rhs * scalar
    }
    
    /// Safely multiplies a vector by a scalar, using Int64 intermediate values to prevent overflow.
    ///
    /// - Parameters:
    ///   - vector: The vector.
    ///   - scalar: The scalar value.
    /// - Returns: The scaled vector, clamped to Int32 range if overflow would occur.
    ///
    /// This method uses Int64 for intermediate calculations to prevent overflow,
    /// then clamps the result to Int32 range. Use this when you need to avoid
    /// wrapping behavior for large values.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 2000000, y: 2000000)
    /// let scaled = IVec2.multiplySafe(v, by: 2)  // Won't overflow
    /// ```
    public static func multiplySafe(_ vector: IVec2, by scalar: Int32) -> IVec2 {
        let xResult = Int64(vector.x) * Int64(scalar)
        let yResult = Int64(vector.y) * Int64(scalar)
        
        return IVec2(
            fixedPointX: Int32(clamping: min(Int64(Int32.max), max(Int64(Int32.min), xResult))),
            fixedPointY: Int32(clamping: min(Int64(Int32.max), max(Int64(Int32.min), yResult)))
        )
    }
    
    /// Computes the squared magnitude using safe multiplication to prevent overflow.
    ///
    /// - Returns: The squared magnitude (Int64).
    ///
    /// This is equivalent to `magnitudeSquared()` but uses safe multiplication
    /// internally. Use this when you need to ensure no intermediate overflow.
    /// Note: `magnitudeSquared()` already uses Int64, so this is mainly for clarity.
    public func magnitudeSquaredSafe() -> Int64 {
        // Already using Int64 to prevent overflow
        let x64 = Int64(x)
        let y64 = Int64(y)
        return x64 * x64 + y64 * y64
    }
}

// MARK: - Game Math Operations

extension IVec2 {
    /// Computes the dot product of two vectors.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The dot product (Int64 to handle overflow).
    ///
    /// **⚠️ This method returns `Int64` (fixed-point product).**
    /// **For game logic, prefer using semantic types and their methods when possible.**
    ///
    /// This method is intended for:
    /// - Internal library use (collision detection, projection, reflection, etc.)
    /// - Advanced use cases where raw `Int64` values are needed
    ///
    /// **Note:** This method requires Int64 intermediate values to prevent overflow
    /// during multiplication, which cannot be efficiently performed using Int32 operations.
    ///
    /// **For game logic, avoid direct Int64 manipulation:**
    /// ```swift
    /// // ✅ Preferred: Use semantic methods that handle conversions internally
    /// let newPos = pos.moveTowards(target: target, maxDistance: 1.0)
    ///
    /// // ❌ Avoid: Direct IVec2 Int64 manipulation in game logic
    /// let dot = vec1.dot(vec2)
    /// if dot > thresholdSq {
    ///     // Error-prone: requires manual threshold quantization
    /// }
    /// ```
    ///
    /// Example (internal library use):
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 2.0)
    /// let v2 = IVec2(x: 0.5, y: 0.3)
    /// let dot = v1.dot(v2)  // 1000 * 500 + 2000 * 300 = 1100000
    /// ```
    @inlinable
    public func dot(_ other: IVec2) -> Int64 {
        // Convert to Int64 before multiplication to prevent overflow
        // This is safe even when x or y values are large (up to Int32.max)
        let x1_64 = Int64(x)
        let y1_64 = Int64(y)
        let x2_64 = Int64(other.x)
        let y2_64 = Int64(other.y)
        return x1_64 * x2_64 + y1_64 * y2_64
    }
    
    /// Computes the squared magnitude (length squared) of the vector.
    ///
    /// - Returns: The squared magnitude (Int64 to handle overflow).
    ///
    /// **⚠️ For game logic using semantic types (`Position2`, `Velocity2`),**
    /// **prefer using `Position2.isWithinDistance(to:threshold:)` instead.**
    ///
    /// This method is intended for:
    /// - Internal library use (collision detection, raycasting, etc.)
    /// - Advanced use cases where raw `Int64` values are needed
    ///
    /// This is faster than `magnitude` and avoids floating-point operations.
    ///
    /// **Note:** This method requires Int64 intermediate values to prevent overflow
    /// during squaring, which cannot be efficiently performed using Int32 operations.
    ///
    /// **For game logic, use semantic types:**
    /// ```swift
    /// // ✅ Preferred: Use Position2 semantic methods
    /// if pos.isWithinDistance(to: target, threshold: 1.0) {
    ///     // Within range
    /// }
    ///
    /// // ❌ Avoid: Direct IVec2 Int64 manipulation in game logic
    /// let magSq = vec.magnitudeSquared()
    /// if magSq < thresholdSq {
    ///     // Error-prone: requires manual threshold quantization
    /// }
    /// ```
    ///
    /// Example (internal library use):
    /// ```swift
    /// let v = IVec2(x: 3.0, y: 4.0)
    /// let magSq = v.magnitudeSquared()  // 3000^2 + 4000^2 = 25000000
    /// ```
    @inlinable
    public func magnitudeSquared() -> Int64 {
        // Convert to Int64 before squaring to prevent overflow
        // This is safe even when x or y values are large (up to Int32.max)
        let x64 = Int64(x)
        let y64 = Int64(y)
        return x64 * x64 + y64 * y64
    }
    
    /// Computes the magnitude (length) of the vector as Float.
    ///
    /// - Returns: The magnitude as Float (dequantized).
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `magnitudeSquared()` instead.
    ///
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 3.0, y: 4.0)
    /// let mag = v.magnitude()  // sqrt(3.0^2 + 4.0^2) = 5.0
    /// ```
    @inlinable
    public func magnitude() -> Float {
        let distSq = magnitudeSquared()
        let dist = FixedPoint.sqrtInt64(distSq)
        return FixedPoint.dequantize(dist)
    }
    
    /// Computes the squared distance to another vector.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The squared distance (Int64 to handle overflow).
    ///
    /// **⚠️ For game logic using semantic types (`Position2`, `Velocity2`),**
    /// **prefer using `Position2.isWithinDistance(to:threshold:)` instead.**
    ///
    /// This method is intended for:
    /// - Internal library use (collision detection, raycasting, etc.)
    /// - Advanced use cases where raw `Int64` values are needed
    ///
    /// This is faster than `distance` and avoids floating-point operations.
    ///
    /// **Note:** This method converts to Int64 and performs squaring to prevent overflow.
    /// The Int64 squaring operations cannot be efficiently performed using Int32 operations.
    ///
    /// **For game logic, use semantic types:**
    /// ```swift
    /// // ✅ Preferred: Use Position2 semantic methods
    /// if pos1.isWithinDistance(to: pos2, threshold: 1.0) {
    ///     // Within range
    /// }
    ///
    /// // ❌ Avoid: Direct IVec2 Int64 manipulation in game logic
    /// let distSq = vec1.distanceSquared(to: vec2)
    /// if distSq < thresholdSq {
    ///     // Error-prone: requires manual threshold quantization
    /// }
    /// ```
    ///
    /// Example (internal library use):
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 2.0)
    /// let v2 = IVec2(x: 4.0, y: 6.0)
    /// let distSq = v1.distanceSquared(to: v2)  // (3000)^2 + (4000)^2 = 25000000
    /// ```
    @inlinable
    public func distanceSquared(to other: IVec2) -> Int64 {
        // Convert to Int64 before squaring to prevent overflow
        // This is safe even when diff values are large (up to Int32.max)
        let dx64 = Int64(x) - Int64(other.x)
        let dy64 = Int64(y) - Int64(other.y)
        return dx64 * dx64 + dy64 * dy64
    }
    
    /// Computes the distance to another vector as Float.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The distance as Float (dequantized).
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `distanceSquared(to:)` instead.
    ///
    @inlinable
    public func distance(to other: IVec2) -> Float {
        let distSq = distanceSquared(to: other)
        let dist = FixedPoint.sqrtInt64(distSq)
        return FixedPoint.dequantize(dist)
    }
    
    /// Normalizes the vector to unit length (as Float).
    ///
    /// - Returns: A normalized vector, or zero vector if magnitude is zero.
    ///
    /// Note: This returns Float values derived from fixed-point normalization.
    /// For deterministic operations, prefer using integer-based APIs in tick logic.
    ///
    @inlinable
    public func normalized() -> (x: Float, y: Float) {
        let normalizedVec = normalizedVec()
        return (normalizedVec.floatX, normalizedVec.floatY)
    }
    
    /// Computes the angle (in radians) of the vector.
    ///
    /// - Returns: The angle in radians as Float.
    ///
    /// Returns angle in range [-π, π] measured from positive x-axis.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 1000, y: 1000)  // 45 degrees
    /// let angle = v.toAngle()  // ≈ 0.785 radians (π/4)
    /// ```
    public func toAngle() -> Float {
        angle().radians
    }
    
    /// Creates a vector from an angle and magnitude.
    ///
    /// - Parameters:
    ///   - angle: The angle in radians.
    ///   - magnitude: The magnitude (will be quantized).
    /// - Returns: A new vector.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2.fromAngle(angle: .pi / 4, magnitude: 1.414)  // ≈ (1, 1)
    /// ```
    public static func fromAngle(angle: Float, magnitude: Float) -> IVec2 {
        let fixedAngle = Angle(radians: angle)
        let fixedMagnitude = FixedPoint.quantize(magnitude)
        return fromAngle(angle: fixedAngle, magnitude: fixedMagnitude)
    }

    /// Creates a vector from a fixed-point angle and fixed-point magnitude.
    ///
    /// - Parameters:
    ///   - angle: The angle as a fixed-point Angle.
    ///   - magnitude: The magnitude in fixed-point units.
    /// - Returns: A new vector.
    public static func fromAngle(angle: Angle, magnitude: Int32) -> IVec2 {
        let (sinValue, cosValue) = FixedPoint.sinCosDegrees(angle.degrees)
        let x64 = Int64(cosValue) * Int64(magnitude) / FixedPoint.trigScale
        let y64 = Int64(sinValue) * Int64(magnitude) / FixedPoint.trigScale
        return IVec2(
            fixedPointX: Int32(clamping: x64),
            fixedPointY: Int32(clamping: y64)
        )
    }
    
    /// Scales this vector by a Float factor and returns a new IVec2.
    ///
    /// - Parameter factor: The scaling factor as Float (will be quantized).
    /// - Returns: A new scaled vector.
    ///
    /// This is useful when you need to scale a normalized direction vector by a distance.
    /// Uses Int64 intermediate calculation to avoid precision loss from quantization.
    ///
    /// **Note:** For small scale factors (< 0.01), this method uses Int64 intermediate
    /// calculation to maintain precision. For larger factors, quantization is acceptable.
    ///
    /// Example:
    /// ```swift
    /// let direction = IVec2(x: 1.0, y: 0.0)  // Unit vector pointing right
    /// let scaled = direction.scaled(by: 2.5)  // IVec2(x: 2.5, y: 0.0)
    /// ```
    @inlinable
    public func scaled(by factor: Float) -> IVec2 {
        let factorQuantized = FixedPoint.quantize(factor)
        return scaled(byFixedPoint: factorQuantized)
    }

    /// Scales this vector by a fixed-point factor and returns a new IVec2.
    ///
    /// - Parameter factor: The scaling factor in fixed-point units.
    /// - Returns: A new scaled vector.
    @inlinable
    public func scaled(byFixedPoint factor: Int32) -> IVec2 {
        let factor64 = Int64(factor)
        let x64 = Int64(x) * factor64 / Int64(FixedPoint.scale)
        let y64 = Int64(y) * factor64 / Int64(FixedPoint.scale)
        return IVec2(
            fixedPointX: Int32(clamping: x64),
            fixedPointY: Int32(clamping: y64)
        )
    }

    /// Computes the fixed-point angle of the vector.
    ///
    /// - Returns: The angle as a fixed-point Angle.
    @inlinable
    public func angle() -> Angle {
        Angle(degrees: FixedPoint.atan2Degrees(y: y, x: x))
    }
    
    /// Returns a normalized version of this vector as IVec2.
    ///
    /// - Returns: A normalized vector, or zero vector if magnitude is zero.
    ///
    /// This is a convenience method that returns an IVec2 instead of (Float, Float).
    /// Uses fixed-point math internally for deterministic results.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 3.0, y: 4.0)
    /// let normalized = v.normalizedVec()  // IVec2(x: 0.6, y: 0.8)
    /// ```
    @inlinable
    public func normalizedVec() -> IVec2 {
        let magSq = magnitudeSquared()
        let mag = FixedPoint.sqrtInt64(magSq)
        guard mag > 0 else {
            return .zero
        }

        let scale = Int64(FixedPoint.scale)
        let x64 = Int64(x) * scale / mag
        let y64 = Int64(y) * scale / mag
        return IVec2(
            fixedPointX: Int32(clamping: x64),
            fixedPointY: Int32(clamping: y64)
        )
    }
    
    /// Rotates the vector by 90 degrees counterclockwise.
    ///
    /// - Returns: A new rotated vector.
    ///
    /// This is a deterministic integer operation (no floating-point).
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 1000, y: 2000)
    /// let rotated = v.rotated90()  // IVec2(x: -2000, y: 1000)
    /// ```
    public func rotated90() -> IVec2 {
        // Rotate 90° CCW: (x, y) -> (-y, x)
        IVec2(fixedPointX: -y, fixedPointY: x)
    }
    
    /// Rotates the vector by -90 degrees (clockwise).
    ///
    /// - Returns: A new rotated vector.
    ///
    /// This is a deterministic integer operation (no floating-point).
    public func rotatedMinus90() -> IVec2 {
        // Rotate -90° (90° CW): (x, y) -> (y, -x)
        IVec2(fixedPointX: y, fixedPointY: -x)
    }
    
    /// Computes the 2D cross product (scalar result).
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The cross product as Int64 (x1 * y2 - y1 * x2).
    ///
    /// In 2D, the cross product is a scalar representing the signed area
    /// of the parallelogram formed by the two vectors.
    ///
    /// **Note:** This method requires Int64 intermediate values to prevent overflow
    /// during multiplication, which cannot be efficiently performed using Int32 operations.
    ///
    /// Example:
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 0.0)
    /// let v2 = IVec2(x: 0.0, y: 1.0)
    /// let cross = v1.cross(v2)  // 1000 (positive, counterclockwise)
    /// ```
    @inlinable
    public func cross(_ other: IVec2) -> Int64 {
        // 2D cross product: x1 * y2 - y1 * x2
        // Convert to Int64 before multiplication to prevent overflow
        return Int64(x) * Int64(other.y) - Int64(y) * Int64(other.x)
    }
    
    /// Projects this vector onto another vector.
    ///
    /// - Parameter other: The vector to project onto.
    /// - Returns: The projection vector.
    ///
    /// The projection is: (this · other / ||other||^2) * other
    ///
    /// Example:
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 1.0)
    /// let v2 = IVec2(x: 1.0, y: 0.0)
    /// let proj = v1.project(onto: v2)  // IVec2(x: 1.0, y: 0.0)
    /// ```
    public func project(onto other: IVec2) -> IVec2 {
        let otherSq = other.magnitudeSquared()
        if otherSq == 0 {
            return IVec2(x: 0.0, y: 0.0)  // Can't project onto zero vector
        }
        
        let dot = self.dot(other)
        let scale = Int64(FixedPoint.scale)
        let (scaledDot, overflow) = dot.multipliedReportingOverflow(by: scale)
        let ratio = overflow ? (dot / otherSq) : (scaledDot / otherSq)
        let ratioScale = overflow ? Int64(1) : scale

        let projX64 = (Int64(other.x) * ratio) / ratioScale
        let projY64 = (Int64(other.y) * ratio) / ratioScale
        return IVec2(
            fixedPointX: Int32(clamping: projX64),
            fixedPointY: Int32(clamping: projY64)
        )
    }
    
    /// Reflects this vector off a surface with the given normal.
    ///
    /// - Parameter normal: The surface normal (should be normalized for best results).
    /// - Returns: The reflected vector.
    ///
    /// Reflection formula: reflected = v - 2 * (v · n) * n
    ///
    /// Example:
    /// ```swift
    /// let velocity = IVec2(x: 1.0, y: -1.0)  // Moving down-right
    /// let normal = IVec2(x: 0.0, y: 1.0)  // Surface pointing up
    /// let reflected = velocity.reflect(off: normal)  // Bounces up-right
    /// ```
    public func reflect(off normal: IVec2) -> IVec2 {
        let dot = self.dot(normal)
        let normalSq = normal.magnitudeSquared()
        
        if normalSq == 0 {
            return self  // Can't reflect off zero normal
        }
        
        // reflected = v - 2 * (v · n / ||n||^2) * n
        let scale = Int64(FixedPoint.scale)
        let (scaledDot, overflowDot) = dot.multipliedReportingOverflow(by: 2)
        let (scaledNumerator, overflowScale) = scaledDot.multipliedReportingOverflow(by: scale)
        let useOverflowPath = overflowDot || overflowScale
        let ratio = useOverflowPath ? (scaledDot / normalSq) : (scaledNumerator / normalSq)
        let ratioScale = useOverflowPath ? Int64(1) : scale

        let scaledX64 = (Int64(normal.x) * ratio) / ratioScale
        let scaledY64 = (Int64(normal.y) * ratio) / ratioScale
        let scaledNormal = IVec2(
            fixedPointX: Int32(clamping: scaledX64),
            fixedPointY: Int32(clamping: scaledY64)
        )
        
        return self - scaledNormal
    }
}

// MARK: - CustomStringConvertible

extension IVec2 {
    /// A textual representation of the vector using dequantized Float values.
    ///
    /// This provides a more intuitive representation for debugging and logging.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 1.5, y: 2.3)
    /// print(v)  // "IVec2(1.5, 2.3)"
    /// ```
    public var description: String {
        "IVec2(\(floatX), \(floatY))"
    }
}

// MARK: - SnapshotValueConvertible

extension IVec2: SnapshotValueConvertible {
    /// Converts IVec2 to SnapshotValue using x and y properties.
    @inlinable
    public func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "x": .int(Int(x)),
            "y": .int(Int(y))
        ])
    }
}

// MARK: - SchemaMetadataProvider

extension IVec2: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    ///
    /// This allows SchemaGen to correctly extract x and y properties
    /// even though they are computed properties.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "x",
                type: Int32.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "y",
                type: Int32.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
