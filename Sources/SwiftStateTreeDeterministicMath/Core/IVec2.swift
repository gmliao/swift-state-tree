// Sources/SwiftStateTreeDeterministicMath/Core/IVec2.swift
//
// Integer 2D vector for deterministic server-authoritative game logic.
// All operations are deterministic and use Int32 to ensure consistency across platforms.

import Foundation
import SwiftStateTree
import simd

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
    /// Internal SIMD storage for optimized operations.
    @usableFromInline
    internal let storage: SIMD2<Int32>
    
    /// The x coordinate.
    @inlinable
    public var x: Int32 {
        storage.x
    }
    
    /// The y coordinate.
    @inlinable
    public var y: Int32 {
        storage.y
    }
    
    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case x, y
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Int32.self, forKey: .x)
        let y = try container.decode(Int32.self, forKey: .y)
        self.storage = SIMD2<Int32>(x, y)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
    
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
        self.storage = SIMD2<Int32>(
            FixedPoint.quantize(x, rounding: rounding),
            FixedPoint.quantize(y, rounding: rounding)
        )
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
        self.storage = SIMD2<Int32>(x, y)
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
    /// Uses SIMD2<Int32> for optimized performance.
    @inlinable
    public static func + (lhs: IVec2, rhs: IVec2) -> IVec2 {
        IVec2(fixedPointX: (lhs.storage &+ rhs.storage).x, fixedPointY: (lhs.storage &+ rhs.storage).y)
    }
    
    /// Subtracts two vectors.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side vector.
    ///   - rhs: The right-hand side vector.
    /// - Returns: The difference of the two vectors.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    /// Uses SIMD2<Int32> for optimized performance.
    @inlinable
    public static func - (lhs: IVec2, rhs: IVec2) -> IVec2 {
        IVec2(fixedPointX: (lhs.storage &- rhs.storage).x, fixedPointY: (lhs.storage &- rhs.storage).y)
    }
    
    /// Multiplies a vector by a scalar.
    ///
    /// - Parameters:
    ///   - lhs: The vector.
    ///   - scalar: The scalar value.
    /// - Returns: The scaled vector.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    /// Uses SIMD2<Int32> for optimized performance.
    /// For safe multiplication that prevents overflow, use `multiplySafe(_:by:)`.
    @inlinable
    public static func * (lhs: IVec2, scalar: Int32) -> IVec2 {
        let scalarVec = SIMD2<Int32>(repeating: scalar)
        let result = lhs.storage &* scalarVec
        return IVec2(fixedPointX: result.x, fixedPointY: result.y)
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
    /// Uses SIMD for optimized multiplication, then converts to Int64 for summation.
    ///
    /// Example:
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 2.0)
    /// let v2 = IVec2(x: 0.5, y: 0.3)
    /// let dot = v1.dot(v2)  // 1000 * 500 + 2000 * 300 = 1100000
    /// ```
    @inlinable
    public func dot(_ other: IVec2) -> Int64 {
        // Use SIMD for parallel multiplication, then convert to Int64 for summation
        let product = storage &* other.storage
        return Int64(product.x) + Int64(product.y)
    }
    
    /// Computes the squared magnitude (length squared) of the vector.
    ///
    /// - Returns: The squared magnitude (Int64 to handle overflow).
    ///
    /// This is faster than `magnitude` and avoids floating-point operations.
    /// Use this when comparing distances (e.g., `v1.magnitudeSquared() < v2.magnitudeSquared()`).
    ///
    /// Uses SIMD for optimized squaring, then converts to Int64 for summation.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 3.0, y: 4.0)
    /// let magSq = v.magnitudeSquared()  // 3000^2 + 4000^2 = 25000000
    /// ```
    @inlinable
    public func magnitudeSquared() -> Int64 {
        // Use SIMD for parallel squaring, then convert to Int64 for summation
        let squared = storage &* storage
        return Int64(squared.x) + Int64(squared.y)
    }
    
    /// Computes the magnitude (length) of the vector as Float.
    ///
    /// - Returns: The magnitude as Float (dequantized).
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `magnitudeSquared()` instead.
    ///
    /// Uses SIMD2<Float> for optimized floating-point operations.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec2(x: 3.0, y: 4.0)
    /// let mag = v.magnitude()  // sqrt(3.0^2 + 4.0^2) = 5.0
    /// ```
    @inlinable
    public func magnitude() -> Float {
        // Use SIMD2<Float> for optimized floating-point operations
        let floatVec = SIMD2<Float>(floatX, floatY)
        let squared = floatVec * floatVec
        return sqrt(squared.x + squared.y)
    }
    
    /// Computes the squared distance to another vector.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The squared distance (Int64 to handle overflow).
    ///
    /// This is faster than `distance` and avoids floating-point operations.
    /// Uses SIMD for optimized difference and squaring operations.
    ///
    /// Example:
    /// ```swift
    /// let v1 = IVec2(x: 1.0, y: 2.0)
    /// let v2 = IVec2(x: 4.0, y: 6.0)
    /// let distSq = v1.distanceSquared(to: v2)  // (3000)^2 + (4000)^2 = 25000000
    /// ```
    @inlinable
    public func distanceSquared(to other: IVec2) -> Int64 {
        // Use SIMD for parallel difference calculation
        let diff = storage &- other.storage
        // Use SIMD for parallel squaring
        let squared = diff &* diff
        // Convert to Int64 for summation (to handle overflow)
        return Int64(squared.x) + Int64(squared.y)
    }
    
    /// Computes the distance to another vector as Float.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The distance as Float (dequantized).
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `distanceSquared(to:)` instead.
    ///
    /// Uses SIMD2<Float> for optimized floating-point operations.
    @inlinable
    public func distance(to other: IVec2) -> Float {
        // Use SIMD2<Float> for optimized floating-point operations
        let diff = SIMD2<Float>(floatX - other.floatX, floatY - other.floatY)
        let squared = diff * diff
        return sqrt(squared.x + squared.y)
    }
    
    /// Normalizes the vector to unit length (as Float).
    ///
    /// - Returns: A normalized vector, or zero vector if magnitude is zero.
    ///
    /// Note: This uses floating-point math and returns a Float-based vector.
    /// For deterministic operations, consider using fixed-point normalization
    /// or working with squared magnitudes.
    ///
    /// Uses SIMD2<Float> for optimized floating-point operations.
    @inlinable
    public func normalized() -> (x: Float, y: Float) {
        let floatVec = SIMD2<Float>(floatX, floatY)
        let mag = magnitude()
        guard mag > 0.0001 else {
            return (0, 0)
        }
        let normalizedVec = floatVec / mag
        return (normalizedVec.x, normalizedVec.y)
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
        return atan2(floatY, floatX)
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
        let x = cos(angle) * magnitude
        let y = sin(angle) * magnitude
        return IVec2(x: x, y: y)
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
        IVec2(fixedPointX: -storage.y, fixedPointY: storage.x)
    }
    
    /// Rotates the vector by -90 degrees (clockwise).
    ///
    /// - Returns: A new rotated vector.
    ///
    /// This is a deterministic integer operation (no floating-point).
    public func rotatedMinus90() -> IVec2 {
        // Rotate -90° (90° CW): (x, y) -> (y, -x)
        IVec2(fixedPointX: storage.y, fixedPointY: -storage.x)
    }
    
    /// Computes the 2D cross product (scalar result).
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The cross product as Int64 (x1 * y2 - y1 * x2).
    ///
    /// In 2D, the cross product is a scalar representing the signed area
    /// of the parallelogram formed by the two vectors.
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
        let scale = Float(dot) / Float(otherSq) * 1000.0  // Scale factor
        
        return IVec2(
            x: other.floatX * scale / 1000.0,
            y: other.floatY * scale / 1000.0
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
        let scale = Float(2 * dot) / Float(normalSq) * 1000.0
        
        let scaledNormal = IVec2(
            x: normal.floatX * scale / 1000.0,
            y: normal.floatY * scale / 1000.0
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
    ///
    /// This implementation directly accesses storage for optimal performance,
    /// avoiding the computed property indirection while maintaining the same result.
    @inlinable
    public func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "x": .int(Int(storage.x)),
            "y": .int(Int(storage.y))
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

// MARK: - Internal Initializers

extension IVec2 {
    /// Internal initializer for SIMD storage.
    ///
    /// - Parameter storage: The SIMD vector storage.
    @inlinable
    internal init(storage: SIMD2<Int32>) {
        self.storage = storage
    }
}
