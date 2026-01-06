// Sources/SwiftStateTreeDeterministicMath/Semantic/Semantic2.swift
//
// Semantic types for 2D positions, velocities, accelerations, and angles.
// These types provide compile-time type safety to prevent mixing positions with velocities.

import Foundation
import SwiftStateTree

/// A 2D position using integer coordinates.
///
/// This semantic type wraps `IVec2` to provide type safety and prevent
/// accidentally mixing positions with velocities or other vector types.
///
/// Example:
/// ```swift
/// let pos = Position2(v: IVec2(x: 1000, y: 2000))
/// let vel = Velocity2(v: IVec2(x: 100, y: 50))
/// let newPos = pos + vel  // Position2 + Velocity2 -> Position2
/// ```
@SnapshotConvertible
public struct Position2: Codable, Equatable, Sendable {
    /// The underlying vector.
    public var v: IVec2
    
    /// Creates a new Position2 with the given vector.
    ///
    /// - Parameter v: The position vector.
    public init(v: IVec2) {
        self.v = v
    }
    
    /// Creates a new Position2 with the given coordinates.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as Float (will be quantized).
    ///   - y: The y coordinate as Float (will be quantized).
    public init(x: Float, y: Float) {
        self.v = IVec2(x: x, y: y)
    }
    
}

/// A 2D velocity using integer coordinates.
///
/// This semantic type wraps `IVec2` to provide type safety and prevent
/// accidentally mixing velocities with positions or other vector types.
@SnapshotConvertible
public struct Velocity2: Codable, Equatable, Sendable {
    /// The underlying vector.
    public var v: IVec2
    
    /// Creates a new Velocity2 with the given vector.
    ///
    /// - Parameter v: The velocity vector.
    public init(v: IVec2) {
        self.v = v
    }
    
    /// Creates a new Velocity2 with the given coordinates.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as Float (will be quantized).
    ///   - y: The y coordinate as Float (will be quantized).
    ///   - rounding: The rounding rule to apply (default: `.toNearestOrAwayFromZero`).
    public init(
        x: Float,
        y: Float,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) {
        self.v = IVec2(x: x, y: y, rounding: rounding)
    }
}

/// A 2D acceleration using integer coordinates.
///
/// This semantic type wraps `IVec2` to provide type safety and prevent
/// accidentally mixing accelerations with positions or velocities.
@SnapshotConvertible
public struct Acceleration2: Codable, Equatable, Sendable {
    /// The underlying vector.
    public var v: IVec2
    
    /// Creates a new Acceleration2 with the given vector.
    ///
    /// - Parameter v: The acceleration vector.
    public init(v: IVec2) {
        self.v = v
    }
    
    /// Creates a new Acceleration2 with the given coordinates.
    ///
    /// - Parameters:
    ///   - x: The x coordinate as Float (will be quantized).
    ///   - y: The y coordinate as Float (will be quantized).
    ///   - rounding: The rounding rule to apply (default: `.toNearestOrAwayFromZero`).
    public init(
        x: Float,
        y: Float,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) {
        self.v = IVec2(x: x, y: y, rounding: rounding)
    }
}

// MARK: - Semantic Operations

extension Position2 {
    /// Adds a velocity to a position.
    ///
    /// - Parameters:
    ///   - lhs: The position.
    ///   - rhs: The velocity.
    /// - Returns: A new position after applying the velocity.
    public static func + (lhs: Position2, rhs: Velocity2) -> Position2 {
        Position2(v: lhs.v + rhs.v)
    }
}

extension Velocity2 {
    /// Adds an acceleration to a velocity.
    ///
    /// - Parameters:
    ///   - lhs: The velocity.
    ///   - rhs: The acceleration.
    /// - Returns: A new velocity after applying the acceleration.
    public static func + (lhs: Velocity2, rhs: Acceleration2) -> Velocity2 {
        Velocity2(v: lhs.v + rhs.v)
    }
}

// MARK: - SchemaMetadataProvider

extension Position2: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "v",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}

extension Velocity2: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "v",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}

extension Acceleration2: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "v",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}

// MARK: - Angle

/// A rotation angle using fixed-point degrees.
///
/// This semantic type wraps Int32 to provide type safety and convenient
/// conversion between degrees and radians. Uses fixed-point: 1000 = 1.0 degree.
///
/// Example:
/// ```swift
/// let angle = Angle(degrees: 45.0)  // 45000 in fixed-point
/// let radians = angle.radians        // ≈ 0.785
/// let angle2 = Angle(radians: .pi / 4)  // Same as above
/// ```
@SnapshotConvertible
public struct Angle: Codable, Equatable, Sendable, Hashable {
    /// Internal storage for the angle in fixed-point degrees (1000 = 1.0 degree).
    /// Using a single Int32 value for efficient operations.
    @usableFromInline
    internal var degrees: Int32
    
    /// Internal initializer for fixed-point degrees.
    ///
    /// This is used internally for operations that already produce quantized values.
    /// External code should use `init(degrees:)` with Float values instead.
    ///
    /// - Parameter degrees: The angle in fixed-point degrees (1000 = 1.0 degree).
    @inlinable
    internal init(degrees: Int32) {
        self.degrees = degrees
    }
    
    /// Creates a new Angle from Float degrees (will be quantized).
    ///
    /// - Parameter degrees: The angle in degrees as Float.
    @inlinable
    public init(degrees: Float) {
        self.degrees = FixedPoint.quantize(degrees)
    }
    
    /// Creates a new Angle from radians (will be quantized).
    ///
    /// - Parameter radians: The angle in radians as Float.
    @inlinable
    public init(radians: Float) {
        let degrees = radians * 180.0 / Float.pi
        self.degrees = FixedPoint.quantize(degrees)
    }
    
    /// The angle in radians as Float.
    @inlinable
    public var radians: Float {
        FixedPoint.dequantize(degrees) * Float.pi / 180.0
    }
    
    /// The angle in degrees as Float.
    @inlinable
    public var floatDegrees: Float {
        FixedPoint.dequantize(degrees)
    }
    
    /// Zero angle (0 degrees).
    public static let zero = Angle(degrees: 0.0)
    
    /// Full circle in fixed-point degrees (360 * 1000 = 360000).
    @inlinable
    public static var fullCircle: Int32 {
        360 * FixedPoint.scale
    }
    
    /// Half circle in fixed-point degrees (180 * 1000 = 180000).
    @inlinable
    public static var halfCircle: Int32 {
        180 * FixedPoint.scale
    }
}

// MARK: - Angle Operations

extension Angle {
    /// Adds two angles together.
    /// Uses wrapping arithmetic for deterministic behavior.
    @inlinable
    public static func + (lhs: Angle, rhs: Angle) -> Angle {
        Angle(degrees: lhs.degrees &+ rhs.degrees)
    }
    
    /// Subtracts one angle from another.
    /// Uses wrapping arithmetic for deterministic behavior.
    @inlinable
    public static func - (lhs: Angle, rhs: Angle) -> Angle {
        Angle(degrees: lhs.degrees &- rhs.degrees)
    }
    
    /// Multiplies an angle by a scalar.
    /// Uses wrapping arithmetic for deterministic behavior.
    @inlinable
    public static func * (lhs: Angle, rhs: Int32) -> Angle {
        Angle(degrees: lhs.degrees &* rhs)
    }
    
    /// Multiplies an angle by a scalar.
    /// Uses wrapping arithmetic for deterministic behavior.
    @inlinable
    public static func * (lhs: Int32, rhs: Angle) -> Angle {
        Angle(degrees: lhs &* rhs.degrees)
    }
    
    /// Negates an angle.
    @inlinable
    public static prefix func - (angle: Angle) -> Angle {
        Angle(degrees: -angle.degrees)
    }
    
    /// Normalizes the angle to the range [0, 360) degrees.
    ///
    /// This wraps the angle to be within a full circle (0-360 degrees).
    /// Uses efficient modulo operation for deterministic behavior.
    ///
    /// - Returns: A normalized angle in the range [0, 360) degrees.
    @inlinable
    public func normalized() -> Angle {
        // Use modulo to wrap to [0, 360) range
        // Handle negative values by adding full circle before modulo
        let normalized = (degrees % Self.fullCircle + Self.fullCircle) % Self.fullCircle
        return Angle(degrees: normalized)
    }
    
    /// Calculates the shortest angular difference between two angles.
    ///
    /// Returns the signed difference in degrees, normalized to [-180, 180) range.
    /// Positive values indicate counterclockwise rotation, negative values indicate clockwise.
    ///
    /// - Parameter other: The target angle.
    /// - Returns: The shortest angular difference in fixed-point degrees.
    ///
    /// Example:
    /// ```swift
    /// let a1 = Angle(degrees: 350.0)  // 350 degrees
    /// let a2 = Angle(degrees: 10.0)    // 10 degrees
    /// let diff = a1.shortestDifference(to: a2)  // 20 degrees (not -340)
    /// ```
    @inlinable
    public func shortestDifference(to other: Angle) -> Angle {
        let diff = other.degrees &- degrees
        // Normalize to [-180, 180) range
        let halfCircle = Self.halfCircle
        let normalized = ((diff + halfCircle) % Self.fullCircle) &- halfCircle
        return Angle(degrees: normalized)
    }
    
    /// Calculates the absolute angular difference between two angles.
    ///
    /// Returns the smallest angle between two angles, always positive.
    ///
    /// - Parameter other: The target angle.
    /// - Returns: The absolute angular difference in fixed-point degrees.
    @inlinable
    public func absoluteDifference(to other: Angle) -> Angle {
        let diff = shortestDifference(to: other)
        return Angle(degrees: abs(diff.degrees))
    }
    
    /// Linearly interpolates between two angles using the shortest path.
    ///
    /// - Parameters:
    ///   - from: The starting angle.
    ///   - to: The target angle.
    ///   - t: The interpolation factor (0.0 = from, 1.0 = to).
    /// - Returns: An interpolated angle.
    @inlinable
    public static func lerp(from: Angle, to: Angle, t: Float) -> Angle {
        let diff = from.shortestDifference(to: to)
        let interpolated = Float(from.degrees) + Float(diff.degrees) * t
        return Angle(degrees: FixedPoint.quantize(interpolated))
    }
}

// MARK: - SchemaMetadataProvider

extension Angle: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "degrees",
                type: Int32.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
