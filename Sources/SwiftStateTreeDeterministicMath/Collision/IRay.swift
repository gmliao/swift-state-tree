// Sources/SwiftStateTreeDeterministicMath/Collision/IRay.swift
//
// Integer ray for 2D collision detection (raycast).
// All operations use integer arithmetic for deterministic behavior.

import Foundation
import SwiftStateTree

/// A 2D ray (half-line) using integer coordinates for deterministic raycast.
///
/// A ray is defined by an origin point and a direction vector.
/// The ray extends infinitely in the direction from the origin.
///
/// Example:
/// ```swift
/// let origin = IVec2(x: 0.0, y: 0.0)
/// let direction = IVec2(x: 1.0, y: 0.0)  // Ray pointing right
/// let ray = IRay(origin: origin, direction: direction)
/// ```
@SnapshotConvertible
public struct IRay: Codable, Equatable, Sendable {
    /// The origin point of the ray.
    public let origin: IVec2
    
    /// The direction vector of the ray (not normalized).
    ///
    /// The ray extends in the direction of this vector from the origin.
    public let direction: IVec2
    
    /// Creates a new IRay with the given origin and direction.
    ///
    /// - Parameters:
    ///   - origin: The starting point of the ray.
    ///   - direction: The direction vector (will be used as-is, not normalized).
    ///
    /// Example:
    /// ```swift
    /// let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), direction: IVec2(x: 1.0, y: 0.0))
    /// ```
    public init(origin: IVec2, direction: IVec2) {
        self.origin = origin
        self.direction = direction
    }
    
    /// Creates a ray from an origin point and an angle.
    ///
    /// - Parameters:
    ///   - origin: The starting point of the ray.
    ///   - angle: The angle in radians.
    ///   - magnitude: The magnitude of the direction vector (default: 1.0).
    ///
    /// Example:
    /// ```swift
    /// let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), angle: .pi / 4, magnitude: 1.0)
    /// ```
    public init(origin: IVec2, angle: Float, magnitude: Float = 1.0) {
        self.origin = origin
        self.direction = IVec2.fromAngle(angle: angle, magnitude: magnitude)
    }
    
    /// Checks if the ray intersects with an AABB.
    ///
    /// - Parameter aabb: The axis-aligned bounding box.
    /// - Returns: The intersection point and distance, or `nil` if no intersection.
    ///
    /// Uses the slab method for efficient AABB-ray intersection.
    ///
    /// Example:
    /// ```swift
    /// let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), direction: IVec2(x: 1.0, y: 0.0))
    /// let box = IAABB2(min: IVec2(x: 0.5, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    /// if let (point, distance) = ray.intersects(aabb: box) {
    ///     // Ray hit the box at point
    /// }
    /// ```
    public func intersects(aabb: IAABB2) -> (point: IVec2, distance: Int64)? {
        // Slab method for AABB-ray intersection
        // We need to handle the case where direction components can be zero
        
        var tMin: Int64 = Int64.min
        var tMax: Int64 = Int64.max
        
        // Check X axis
        if direction.x == 0 {
            // Ray is parallel to X axis
            if origin.x < aabb.min.x || origin.x > aabb.max.x {
                return nil  // Ray is outside the AABB
            }
        } else {
            let invD = Int64(1_000_000_000) / Int64(direction.x)  // Use large scale for precision
            var t1 = (Int64(aabb.min.x) - Int64(origin.x)) * invD / 1_000_000
            var t2 = (Int64(aabb.max.x) - Int64(origin.x)) * invD / 1_000_000
            
            if t1 > t2 {
                swap(&t1, &t2)
            }
            
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            
            if tMin > tMax {
                return nil
            }
        }
        
        // Check Y axis
        if direction.y == 0 {
            // Ray is parallel to Y axis
            if origin.y < aabb.min.y || origin.y > aabb.max.y {
                return nil  // Ray is outside the AABB
            }
        } else {
            let invD = Int64(1_000_000_000) / Int64(direction.y)
            var t1 = (Int64(aabb.min.y) - Int64(origin.y)) * invD / 1_000_000
            var t2 = (Int64(aabb.max.y) - Int64(origin.y)) * invD / 1_000_000
            
            if t1 > t2 {
                swap(&t1, &t2)
            }
            
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            
            if tMin > tMax {
                return nil
            }
        }
        
        // If we get here, the ray intersects the AABB
        // Return the closest intersection point (tMin)
        if tMin < 0 {
            return nil  // Ray starts behind the AABB
        }
        
        // Calculate intersection point
        let t = Float(tMin) / 1000.0  // Convert back to float scale
        let dirFloat = direction
        let point = IVec2(
            x: origin.floatX + dirFloat.floatX * t,
            y: origin.floatY + dirFloat.floatY * t
        )
        
        return (point, tMin)
    }
    
    /// Checks if the ray intersects with a circle.
    ///
    /// - Parameter circle: The circle to test against.
    /// - Returns: The intersection point(s) and distance(s), or `nil` if no intersection.
    ///
    /// Returns the closest intersection point if the ray hits the circle.
    /// Uses SIMD-optimized vector operations via IVec2 (subtraction, dot product, magnitudeSquared, distanceSquared).
    ///
    /// Example:
    /// ```swift
    /// let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), direction: IVec2(x: 1.0, y: 0.0))
    /// let circle = ICircle(center: IVec2(x: 1.0, y: 0.0), radius: 0.3)
    /// if let (point, distance) = ray.intersects(circle: circle) {
    ///     // Ray hit the circle at point
    /// }
    /// ```
    @inlinable
    public func intersects(circle: ICircle) -> (point: IVec2, distance: Int64)? {
        // All IVec2 operations use SIMD
        // Vector from circle center to ray origin
        let toOrigin = origin - circle.center  // SIMD-optimized subtraction
        
        // Project toOrigin onto direction to get the closest point on the ray to the circle center
        let dirSq = direction.magnitudeSquared()  // SIMD-optimized
        if dirSq == 0 {
            return nil  // Zero direction vector
        }
        
        let projection = toOrigin.dot(direction)  // SIMD-optimized dot product
        let tProjection = Float(projection) / Float(dirSq) * 1000.0  // Scale factor
        
        if tProjection < 0 {
            // Closest point is behind the ray origin, check if origin is inside circle
            let distSq = origin.distanceSquared(to: circle.center)  // SIMD-optimized
            let radiusSq = Int64(circle.radius) * Int64(circle.radius)
            if distSq <= radiusSq {
                return (origin, 0)
            }
            return nil
        }
        
        // Calculate closest point on ray to circle center
        let closestPoint = IVec2(
            x: origin.floatX + direction.floatX * (tProjection / 1000.0),
            y: origin.floatY + direction.floatY * (tProjection / 1000.0)
        )
        
        // Check if closest point is within circle radius
        let distSq = closestPoint.distanceSquared(to: circle.center)  // SIMD-optimized
        let radiusSq = Int64(circle.radius) * Int64(circle.radius)
        
        if distSq > radiusSq {
            return nil  // Ray doesn't intersect circle
        }
        
        // Calculate actual intersection point(s)
        // We need to solve: ||origin + t * direction - center|| = radius
        // This is a quadratic equation: a*t^2 + b*t + c = 0
        
        let a = direction.magnitudeSquared()  // SIMD-optimized
        let b = Int64(2) * toOrigin.dot(direction)  // SIMD-optimized dot product
        let c = toOrigin.magnitudeSquared() - radiusSq  // SIMD-optimized
        
        // Discriminant
        let discriminant = b * b - Int64(4) * a * c
        
        if discriminant < 0 {
            return nil  // No real solutions
        }
        
        // Calculate t (use the smaller positive t for the first intersection)
        let sqrtDisc = Int64(sqrt(Float(discriminant)))
        let t1 = (-b - sqrtDisc) / (Int64(2) * a)
        let t2 = (-b + sqrtDisc) / (Int64(2) * a)
        
        let t = min(t1, t2)
        if t < 0 {
            return nil  // Intersection is behind the ray origin
        }
        
        // Calculate intersection point
        let tFloat = Float(t) / 1000.0
        let point = IVec2(
            x: origin.floatX + direction.floatX * tFloat,
            y: origin.floatY + direction.floatY * tFloat
        )
        
        return (point, t)
    }
}

// MARK: - SchemaMetadataProvider

extension IRay: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "origin",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "direction",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
