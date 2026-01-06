// Sources/SwiftStateTreeDeterministicMath/Semantic/Semantic2.swift
//
// Semantic types for 2D positions, velocities, and accelerations.
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
    public init(x: Float, y: Float) {
        self.v = IVec2(x: x, y: y)
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
    public init(x: Float, y: Float) {
        self.v = IVec2(x: x, y: y)
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
