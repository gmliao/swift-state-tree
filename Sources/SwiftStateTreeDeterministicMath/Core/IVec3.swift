// Sources/SwiftStateTreeDeterministicMath/Core/IVec3.swift
//
// Integer 3D vector for deterministic server-authoritative game logic.
// All operations are deterministic and use Int32 to ensure consistency across platforms.

import Foundation
import SwiftStateTree

/// A 3D vector using Int32 coordinates for deterministic math.
///
/// This type is designed for server-authoritative game logic where determinism
/// is critical for replay and synchronization. All operations use integer arithmetic
/// to ensure consistent behavior across different platforms and architectures.
///
/// Example:
/// ```swift
/// let v1 = IVec3(x: 1000, y: 2000, z: 3000)
/// let v2 = IVec3(x: 500, y: 300, z: 100)
/// let sum = v1 + v2  // IVec3(x: 1500, y: 2300, z: 3100)
/// ```
public struct IVec3: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The x coordinate.
    public let x: Int32
    
    /// The y coordinate.
    public let y: Int32
    
    /// The z coordinate.
    public let z: Int32
    
    // MARK: - Codable Implementation
    
    // Codable is automatically synthesized since x, y, and z are stored properties
    
    /// Creates a new IVec3 from Float coordinates.
    ///
    /// This is the recommended way to create IVec3 instances, as it automatically
    /// quantizes Float values to fixed-point integers using the configured scale.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as Float (will be quantized).
    ///   - y: The y coordinate as Float (will be quantized).
    ///   - z: The z coordinate as Float (will be quantized).
    ///   - rounding: The rounding rule to apply (default: `.toNearestOrAwayFromZero`).
    ///
    /// Example:
    /// ```swift
    /// let v = IVec3(x: 1.5, y: 2.3, z: 3.7)  // Quantized to (1500, 2300, 3700) with scale 1000
    /// ```
    public init(
        x: Float,
        y: Float,
        z: Float,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) {
        self.x = FixedPoint.quantize(x, rounding: rounding)
        self.y = FixedPoint.quantize(y, rounding: rounding)
        self.z = FixedPoint.quantize(z, rounding: rounding)
    }
    
    /// Internal initializer for fixed-point integer coordinates.
    ///
    /// This is used internally for operations that already produce quantized values.
    /// External code should use `init(x:y:z:)` with Float values instead.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as fixed-point Int32.
    ///   - y: The y coordinate as fixed-point Int32.
    ///   - z: The z coordinate as fixed-point Int32.
    @inlinable
    internal init(fixedPointX x: Int32, fixedPointY y: Int32, fixedPointZ z: Int32) {
        self.x = x
        self.y = y
        self.z = z
    }
    
    /// The x coordinate as Float (dequantized).
    public var floatX: Float {
        FixedPoint.dequantize(x)
    }
    
    /// The y coordinate as Float (dequantized).
    public var floatY: Float {
        FixedPoint.dequantize(y)
    }
    
    /// The z coordinate as Float (dequantized).
    public var floatZ: Float {
        FixedPoint.dequantize(z)
    }
    
    /// The zero vector.
    public static let zero = IVec3(fixedPointX: 0, fixedPointY: 0, fixedPointZ: 0)
}

// MARK: - Arithmetic Operations

extension IVec3 {
    /// Adds two vectors.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side vector.
    ///   - rhs: The right-hand side vector.
    /// - Returns: The sum of the two vectors.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    @inlinable
    public static func + (lhs: IVec3, rhs: IVec3) -> IVec3 {
        IVec3(fixedPointX: lhs.x &+ rhs.x, 
              fixedPointY: lhs.y &+ rhs.y,
              fixedPointZ: lhs.z &+ rhs.z)
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
    public static func - (lhs: IVec3, rhs: IVec3) -> IVec3 {
        IVec3(fixedPointX: lhs.x &- rhs.x,
              fixedPointY: lhs.y &- rhs.y,
              fixedPointZ: lhs.z &- rhs.z)
    }
    
    /// Multiplies a vector by a scalar.
    ///
    /// - Parameters:
    ///   - lhs: The vector.
    ///   - scalar: The scalar value.
    /// - Returns: The scaled vector.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    @inlinable
    public static func * (lhs: IVec3, scalar: Int32) -> IVec3 {
        IVec3(fixedPointX: lhs.x &* scalar, fixedPointY: lhs.y &* scalar, fixedPointZ: lhs.z &* scalar)
    }
    
    /// Multiplies a scalar by a vector.
    ///
    /// - Parameters:
    ///   - scalar: The scalar value.
    ///   - rhs: The vector.
    /// - Returns: The scaled vector.
    ///
    /// Note: Overflow behavior is wrapping (deterministic).
    public static func * (scalar: Int32, rhs: IVec3) -> IVec3 {
        rhs * scalar
    }
}

// MARK: - Game Math Operations

extension IVec3 {
    /// Computes the dot product of two vectors.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The dot product (Int64 to handle overflow).
    public func dot(_ other: IVec3) -> Int64 {
        // Convert to Int64 before multiplication to prevent overflow
        Int64(x) * Int64(other.x) + 
        Int64(y) * Int64(other.y) + 
        Int64(z) * Int64(other.z)
    }
    
    /// Computes the cross product of two vectors.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The cross product vector.
    ///
    /// Example:
    /// ```swift
    /// let v1 = IVec3(x: 1000, y: 0, z: 0)  // x-axis
    /// let v2 = IVec3(x: 0, y: 1000, z: 0)  // y-axis
    /// let cross = v1.cross(v2)  // IVec3(x: 0, y: 0, z: 1000000)  // z-axis
    /// ```
    public func cross(_ other: IVec3) -> IVec3 {
        // cross = (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        // Uses Int64 to prevent overflow during intermediate calculations
        IVec3(
            fixedPointX: Int32(Int64(y) * Int64(other.z) - Int64(z) * Int64(other.y)),
            fixedPointY: Int32(Int64(z) * Int64(other.x) - Int64(x) * Int64(other.z)),
            fixedPointZ: Int32(Int64(x) * Int64(other.y) - Int64(y) * Int64(other.x))
        )
    }
    
    /// Computes the squared magnitude (length squared) of the vector.
    ///
    /// - Returns: The squared magnitude (Int64 to handle overflow).
    public func magnitudeSquared() -> Int64 {
        // Convert to Int64 before squaring to prevent overflow
        Int64(x) * Int64(x) + 
        Int64(y) * Int64(y) + 
        Int64(z) * Int64(z)
    }
    
    /// Computes the magnitude (length) of the vector as Float.
    ///
    /// - Returns: The magnitude as Float (dequantized).
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `magnitudeSquared()` instead.
    public func magnitude() -> Float {
        let x64 = Int64(x)
        let y64 = Int64(y)
        let z64 = Int64(z)
        let distSq = x64 * x64 + y64 * y64 + z64 * z64
        let dist = FixedPoint.sqrtInt64(distSq)
        return FixedPoint.dequantize(dist)
    }
    
    /// Computes the squared distance to another vector.
    ///
    /// - Parameter other: The other vector.
    /// - Returns: The squared distance (Int64 to handle overflow).
    public func distanceSquared(to other: IVec3) -> Int64 {
        // Convert to Int64 before squaring to prevent overflow
        let dx = Int64(x) - Int64(other.x)
        let dy = Int64(y) - Int64(other.y)
        let dz = Int64(z) - Int64(other.z)
        return dx * dx + dy * dy + dz * dz
    }
}

// MARK: - CustomStringConvertible

extension IVec3 {
    /// A textual representation of the vector using dequantized Float values.
    ///
    /// This provides a more intuitive representation for debugging and logging.
    ///
    /// Example:
    /// ```swift
    /// let v = IVec3(x: 1.5, y: 2.3, z: 3.7)
    /// print(v)  // "IVec3(1.5, 2.3, 3.7)"
    /// ```
    public var description: String {
        "IVec3(\(floatX), \(floatY), \(floatZ))"
    }
}

// MARK: - SnapshotValueConvertible

extension IVec3: SnapshotValueConvertible {
    /// Converts IVec3 to SnapshotValue using x, y, and z properties.
    @inlinable
    public func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "x": .int(Int(x)),
            "y": .int(Int(y)),
            "z": .int(Int(z))
        ])
    }
}

// MARK: - SchemaMetadataProvider

extension IVec3: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    ///
    /// This allows SchemaGen to correctly extract x, y, and z properties
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
            ),
            FieldMetadata(
                name: "z",
                type: Int32.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
