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
        let fixedAngle = Angle(radians: angle)
        let fixedMagnitude = FixedPoint.quantize(magnitude)
        self.direction = IVec2.fromAngle(angle: fixedAngle, magnitude: fixedMagnitude)
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
            // Use scaleCubed for high-precision division to avoid loss of precision
            let invD = FixedPoint.scaleCubed / Int64(direction.x)
            var t1 = (Int64(aabb.min.x) - Int64(origin.x)) * invD / FixedPoint.scaleSquared
            var t2 = (Int64(aabb.max.x) - Int64(origin.x)) * invD / FixedPoint.scaleSquared
            
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
            // Use scaleCubed for high-precision division to avoid loss of precision
            let invD = FixedPoint.scaleCubed / Int64(direction.y)
            var t1 = (Int64(aabb.min.y) - Int64(origin.y)) * invD / FixedPoint.scaleSquared
            var t2 = (Int64(aabb.max.y) - Int64(origin.y)) * invD / FixedPoint.scaleSquared
            
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
        
        // Calculate intersection point (fixed-point)
        let scale = Int64(FixedPoint.scale)
        let pointX = Int64(origin.x) + (Int64(direction.x) * tMin) / scale
        let pointY = Int64(origin.y) + (Int64(direction.y) * tMin) / scale
        let point = IVec2(
            fixedPointX: Int32(clamping: pointX),
            fixedPointY: Int32(clamping: pointY)
        )
        
        return (point, tMin)
    }
    
    /// Checks if the ray intersects with a circle.
    ///
    /// - Parameter circle: The circle to test against.
    /// - Returns: The intersection point(s) and distance(s), or `nil` if no intersection.
    ///
    /// Returns the closest intersection point if the ray hits the circle.
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` (≈ ±1,073,741,823 fixed-point units,
    ///   or ±1,073,741.823 Float units with scale 1000) to prevent `Int64` overflow in distance calculations.
    /// - **Radius:** Circle radius must be within `FixedPoint.MAX_CIRCLE_RADIUS` to ensure compatibility.
    ///
    /// **Overflow Handling:** Uses overflow detection to handle edge cases deterministically.
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
        // Vector from circle center to ray origin
        let toOrigin = origin - circle.center
        
        // Project toOrigin onto direction to get the closest point on the ray to the circle center
        let dirSq = direction.magnitudeSquared()
        if dirSq == 0 {
            return nil  // Zero direction vector
        }
        
        let projection = toOrigin.dot(direction)
        let scale = Int64(FixedPoint.scale)
        let (scaledProjection, overflow) = projection.multipliedReportingOverflow(by: scale)
        let tProjection = overflow ? (projection / dirSq) : (scaledProjection / dirSq)
        let tScale = overflow ? Int64(1) : scale
        
        if tProjection < 0 {
            // Closest point is behind the ray origin, check if origin is inside circle
            // Directly compute distance using Int64 to avoid Int32 overflow
            let dx64 = Int64(origin.x) - Int64(circle.center.x)
            let dy64 = Int64(origin.y) - Int64(circle.center.y)
            
            let (distSqX, distOverflowX) = dx64.multipliedReportingOverflow(by: dx64)
            if distOverflowX {
                return nil  // Origin is extremely far away, no intersection
            }
            let (distSqY, distOverflowY) = dy64.multipliedReportingOverflow(by: dy64)
            if distOverflowY {
                return nil
            }
            let (distSq, distOverflow) = distSqX.addingReportingOverflow(distSqY)
            if distOverflow {
                return nil
            }
            
            let (radiusSq, radiusOverflow) = circle.radius.multipliedReportingOverflow(by: circle.radius)
            if radiusOverflow {
                // If radius squared overflows, treat as always intersecting (conservative)
                return (origin, 0)
            }
            
            if distSq <= radiusSq {
                return (origin, 0)
            }
            return nil
        }
        
        // Calculate closest point on ray to circle center
        let closestX = Int64(origin.x) + (Int64(direction.x) * tProjection) / tScale
        let closestY = Int64(origin.y) + (Int64(direction.y) * tProjection) / tScale
        let closestPoint = IVec2(
            fixedPointX: Int32(clamping: closestX),
            fixedPointY: Int32(clamping: closestY)
        )
        
        // Check if closest point is within circle radius
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(closestPoint.x) - Int64(circle.center.x)
        let dy64 = Int64(closestPoint.y) - Int64(circle.center.y)
        
        let (distSqX, distOverflowX) = dx64.multipliedReportingOverflow(by: dx64)
        if distOverflowX {
            return nil  // Closest point is extremely far away, no intersection
        }
        let (distSqY, distOverflowY) = dy64.multipliedReportingOverflow(by: dy64)
        if distOverflowY {
            return nil
        }
        let (distSq, distOverflow) = distSqX.addingReportingOverflow(distSqY)
        if distOverflow {
            return nil
        }
        
        let (radiusSq, radiusOverflow) = circle.radius.multipliedReportingOverflow(by: circle.radius)
        if radiusOverflow {
            // If radius squared overflows, treat as always intersecting (conservative)
            return (closestPoint, tProjection)
        }
        
        if distSq > radiusSq {
            return nil  // Ray doesn't intersect circle
        }
        
        let dirLen = FixedPoint.sqrtInt64(dirSq)
        if dirLen == 0 {
            return nil
        }

        let offset = FixedPoint.sqrtInt64(radiusSq - distSq)
        let thc = (offset * tScale) / dirLen
        let tHit = tProjection - thc
        let tHitAlt = tProjection + thc
        let finalT = tHit >= 0 ? tHit : tHitAlt
        if finalT < 0 {
            return nil
        }

        let pointX = Int64(origin.x) + (Int64(direction.x) * finalT) / tScale
        let pointY = Int64(origin.y) + (Int64(direction.y) * finalT) / tScale
        let point = IVec2(
            fixedPointX: Int32(clamping: pointX),
            fixedPointY: Int32(clamping: pointY)
        )
        
        return (point, finalT)
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
