// Sources/SwiftStateTreeDeterministicMath/Collision/ICircle.swift
//
// Integer circle for 2D collision detection.
// All operations use integer arithmetic for deterministic behavior.

import Foundation
import SwiftStateTree

/// A circle using integer coordinates for deterministic collision detection.
///
/// This type is used for circular collision detection in deterministic
/// game logic. All operations use integer arithmetic to ensure consistency.
///
/// Example:
/// ```swift
/// let circle1 = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
/// let circle2 = ICircle(center: IVec2(x: 1.0, y: 0.0), radius: 0.5)
/// let intersects = circle1.intersects(circle2)  // true (touching)
/// ```
@SnapshotConvertible
public struct ICircle: Codable, Equatable, Sendable {
    /// The center point of the circle.
    public let center: IVec2
    
    /// The radius of the circle (as fixed-point integer).
    ///
    /// For example, radius of 0.5 would be stored as 500 (with scale 1000).
    public let radius: Int32
    
    /// Creates a new ICircle with the given center and radius.
    ///
    /// - Parameters:
    ///   - center: The center point of the circle.
    ///   - radius: The radius as a Float (will be quantized).
    ///
    /// Example:
    /// ```swift
    /// let circle = ICircle(center: IVec2(x: 1.0, y: 2.0), radius: 0.5)
    /// ```
    public init(center: IVec2, radius: Float) {
        self.center = center
        self.radius = FixedPoint.quantize(radius)
    }
    
    /// Creates a new ICircle with the given center and fixed-point radius.
    ///
    /// - Parameters:
    ///   - center: The center point of the circle.
    ///   - fixedPointRadius: The radius as a fixed-point integer.
    ///
    /// This is an internal initializer for performance-critical code.
    @inlinable
    internal init(center: IVec2, fixedPointRadius: Int32) {
        self.center = center
        self.radius = fixedPointRadius
    }
    
    /// The radius as a Float (dequantized).
    @inlinable
    public var floatRadius: Float {
        FixedPoint.dequantize(radius)
    }
    
    /// Checks if a point is inside the circle.
    ///
    /// - Parameter point: The point to check.
    /// - Returns: `true` if the point is inside or on the circle boundary.
    ///
    /// Uses squared distance comparison to avoid floating-point operations.
    /// Uses SIMD-optimized distance calculation via IVec2.
    @inlinable
    public func contains(_ point: IVec2) -> Bool {
        // distanceSquared uses SIMD internally
        let distSq = center.distanceSquared(to: point)
        let radiusSq = Int64(radius) * Int64(radius)
        return distSq <= radiusSq
    }
    
    /// Checks if this circle intersects with another circle.
    ///
    /// - Parameter other: The other circle.
    /// - Returns: `true` if the circles intersect (touch or overlap).
    ///
    /// Uses squared distance comparison to avoid floating-point operations.
    /// Uses SIMD-optimized distance calculation via IVec2.
    ///
    /// Example:
    /// ```swift
    /// let c1 = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
    /// let c2 = ICircle(center: IVec2(x: 0.8, y: 0.0), radius: 0.5)
    /// let intersects = c1.intersects(c2)  // true (overlapping)
    /// ```
    @inlinable
    public func intersects(_ other: ICircle) -> Bool {
        // distanceSquared uses SIMD internally
        let distSq = center.distanceSquared(to: other.center)
        let radiusSum = Int64(radius) + Int64(other.radius)
        let radiusSumSq = radiusSum * radiusSum
        return distSq <= radiusSumSq
    }
    
    /// Checks if this circle intersects with an AABB.
    ///
    /// - Parameter aabb: The axis-aligned bounding box.
    /// - Returns: `true` if the circle intersects with the AABB.
    ///
    /// This uses the closest point on the AABB to the circle center,
    /// then checks if that point is within the circle radius.
    /// Uses SIMD-optimized distance calculation via IVec2.
    ///
    /// Example:
    /// ```swift
    /// let circle = ICircle(center: IVec2(x: 0.5, y: 0.5), radius: 0.3)
    /// let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    /// let intersects = circle.intersects(aabb: box)  // true
    /// ```
    @inlinable
    public func intersects(aabb: IAABB2) -> Bool {
        // Find the closest point on the AABB to the circle center
        let closestPoint = aabb.clamp(center)
        
        // distanceSquared uses SIMD internally
        let distSq = center.distanceSquared(to: closestPoint)
        let radiusSq = Int64(radius) * Int64(radius)
        return distSq <= radiusSq
    }
    
    /// Computes the squared distance from a point to the circle boundary.
    ///
    /// - Parameter point: The point to measure from.
    /// - Returns: The squared distance. Negative if the point is inside the circle.
    ///
    /// This is useful for collision detection and spatial queries.
    /// Uses SIMD-optimized distance calculation via IVec2.
    @inlinable
    public func distanceSquaredToBoundary(from point: IVec2) -> Int64 {
        // distanceSquared uses SIMD internally
        let distSq = center.distanceSquared(to: point)
        let radiusSq = Int64(radius) * Int64(radius)
        return distSq - radiusSq
    }
    
    /// Computes the bounding AABB of this circle.
    ///
    /// - Returns: An AABB that fully contains the circle.
    ///
    /// Uses SIMD-optimized vector operations for performance.
    ///
    /// Example:
    /// ```swift
    /// let circle = ICircle(center: IVec2(x: 0.5, y: 0.5), radius: 0.3)
    /// let aabb = circle.boundingAABB()
    /// // aabb.min ≈ (0.2, 0.2), aabb.max ≈ (0.8, 0.8)
    /// ```
    @inlinable
    public func boundingAABB() -> IAABB2 {
        // Use SIMD for optimized vector operations
        let radiusVec = IVec2(fixedPointX: radius, fixedPointY: radius)
        // IVec2 subtraction and addition already use SIMD internally
        return IAABB2(
            min: center - radiusVec,
            max: center + radiusVec
        )
    }
}

// MARK: - SchemaMetadataProvider

extension ICircle: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "center",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "radius",
                type: Int32.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
