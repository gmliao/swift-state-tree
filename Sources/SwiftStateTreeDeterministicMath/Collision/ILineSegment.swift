// Sources/SwiftStateTreeDeterministicMath/Collision/ILineSegment.swift
//
// Integer line segment for 2D collision detection.
// All operations use integer arithmetic for deterministic behavior.

import Foundation
import SwiftStateTree

/// A 2D line segment using integer coordinates for deterministic collision detection.
///
/// A line segment is defined by two endpoints. Unlike a ray, it has finite length.
///
/// Example:
/// ```swift
/// let segment = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 1.0))
/// let distance = segment.distanceToPoint(IVec2(x: 0.5, y: 0.0))  // Distance to segment
/// ```
@SnapshotConvertible
public struct ILineSegment: Codable, Equatable, Sendable {
    /// The start point of the line segment.
    public let start: IVec2
    
    /// The end point of the line segment.
    public let end: IVec2
    
    /// Creates a new ILineSegment with the given endpoints.
    ///
    /// - Parameters:
    ///   - start: The start point of the segment.
    ///   - end: The end point of the segment.
    ///
    /// Example:
    /// ```swift
    /// let segment = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 1.0))
    /// ```
    public init(start: IVec2, end: IVec2) {
        self.start = start
        self.end = end
    }
    
    /// The direction vector of the segment (from start to end).
    @inlinable
    public var direction: IVec2 {
        end - start
    }
    
    /// The length of the segment as Float.
    @inlinable
    public var length: Float {
        direction.magnitude()
    }
    
    /// The squared length of the segment (Int64 to handle overflow).
    @inlinable
    public var lengthSquared: Int64 {
        direction.magnitudeSquared()
    }
    
    /// Computes the squared distance from a point to this line segment.
    ///
    /// - Parameter point: The point to measure from.
    /// - Returns: The squared distance to the closest point on the segment.
    ///
    /// This is faster than `distanceToPoint` and avoids floating-point operations.
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` to prevent `Int64` overflow.
    ///
    /// Example:
    /// ```swift
    /// let segment = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 0.0))
    /// let distSq = segment.distanceSquaredToPoint(IVec2(x: 0.5, y: 0.5))  // 0.25
    /// ```
    @inlinable
    public func distanceSquaredToPoint(_ point: IVec2) -> Int64 {
        // Compute distance directly using Int64
        let toStart = point - start
        let dir = direction
        
        let dirSq = dir.magnitudeSquared()
        if dirSq == 0 {
            // Segment is a point, return distance to that point
            // Directly compute distance using Int64
            let dx64 = Int64(toStart.x)
            let dy64 = Int64(toStart.y)
            let (distSqX, _) = dx64.multipliedReportingOverflow(by: dx64)
            let (distSqY, _) = dy64.multipliedReportingOverflow(by: dy64)
            let (distSq, _) = distSqX.addingReportingOverflow(distSqY)
            return distSq
        }
        
        // Project point onto the line segment
        let t = toStart.dot(dir)
        
        if t <= 0 {
            // Closest point is the start point
            // Directly compute distance using Int64
            let dx64 = Int64(toStart.x)
            let dy64 = Int64(toStart.y)
            let (distSqX, _) = dx64.multipliedReportingOverflow(by: dx64)
            let (distSqY, _) = dy64.multipliedReportingOverflow(by: dy64)
            let (distSq, _) = distSqX.addingReportingOverflow(distSqY)
            return distSq
        }
        
        if t >= dirSq {
            // Closest point is the end point
            let toEnd = point - end
            // Directly compute distance using Int64
            let dx64 = Int64(toEnd.x)
            let dy64 = Int64(toEnd.y)
            let (distSqX, _) = dx64.multipliedReportingOverflow(by: dx64)
            let (distSqY, _) = dy64.multipliedReportingOverflow(by: dy64)
            let (distSq, _) = distSqX.addingReportingOverflow(distSqY)
            return distSq
        }
        
        // Closest point is on the segment
        // Calculate the closest point: start + (t / dirSq) * dir
        // Distance squared = ||point - (start + (t / dirSq) * dir)||^2
        
        // Calculate closest point using Float for precision, then convert back
        let tFloat = Float(t) / Float(dirSq)
        let closestPoint = IVec2(
            x: start.floatX + dir.floatX * tFloat,
            y: start.floatY + dir.floatY * tFloat
        )
        
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(point.x) - Int64(closestPoint.x)
        let dy64 = Int64(point.y) - Int64(closestPoint.y)
        let (distSqX, _) = dx64.multipliedReportingOverflow(by: dx64)
        let (distSqY, _) = dy64.multipliedReportingOverflow(by: dy64)
        let (distSq, _) = distSqX.addingReportingOverflow(distSqY)
        return distSq
    }
    
    /// Computes the distance from a point to this line segment as Float.
    ///
    /// - Parameter point: The point to measure from.
    /// - Returns: The distance to the closest point on the segment.
    ///
    /// Note: This uses floating-point math. For deterministic comparisons,
    /// use `distanceSquaredToPoint` instead.
    public func distanceToPoint(_ point: IVec2) -> Float {
        let distSq = distanceSquaredToPoint(point)
        return sqrt(Float(distSq) / FixedPoint.scaleSquaredFloat)
    }
    
    /// Checks if this line segment intersects with another line segment.
    ///
    /// - Parameter other: The other line segment.
    /// - Returns: The intersection point, or `nil` if they don't intersect.
    ///
    /// Uses the parametric line equation to find intersection.
    ///
    /// Example:
    /// ```swift
    /// let seg1 = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 1.0))
    /// let seg2 = ILineSegment(start: IVec2(x: 0.0, y: 1.0), end: IVec2(x: 1.0, y: 0.0))
    /// if let point = seg1.intersects(seg2) {
    ///     // Segments intersect at point
    /// }
    /// ```
    public func intersects(_ other: ILineSegment) -> IVec2? {
        let d1 = direction
        let d2 = other.direction
        
        // Vector from this start to other start
        let r = other.start - start
        
        // Cross product of direction vectors
        // In 2D, cross product is: a.x * b.y - a.y * b.x
        let crossD1D2 = Int64(d1.x) * Int64(d2.y) - Int64(d1.y) * Int64(d2.x)
        
        // If cross product is zero, lines are parallel
        if crossD1D2 == 0 {
            return nil  // Parallel lines (may be collinear, but we treat as no intersection)
        }
        
        // Calculate t and u parameters
        // t = cross(r, d2) / cross(d1, d2)
        // u = cross(r, d1) / cross(d1, d2)
        let crossRD2 = r.cross(d2)
        let crossRD1 = r.cross(d1)
        
        let t = Float(crossRD2) / Float(crossD1D2)
        let u = Float(crossRD1) / Float(crossD1D2)
        
        // Check if intersection is within both segments
        if t < 0 || t > 1 || u < 0 || u > 1 {
            return nil  // Intersection is outside one or both segments
        }
        
        // Calculate intersection point
        let intersection = IVec2(
            x: start.floatX + d1.floatX * t,
            y: start.floatY + d1.floatY * t
        )
        
        return intersection
    }
    
    /// Checks if this line segment intersects with a circle.
    ///
    /// - Parameter circle: The circle to test against.
    /// - Returns: The intersection point(s), or `nil` if no intersection.
    ///
    /// Returns the closest intersection point if the segment hits the circle.
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
    /// let segment = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 0.0))
    /// let circle = ICircle(center: IVec2(x: 0.5, y: 0.0), radius: 0.2)
    /// if let point = segment.intersects(circle: circle) {
    ///     // Segment intersects circle at point
    /// }
    /// ```
    @inlinable
    public func intersects(circle: ICircle) -> IVec2? {
        // Vector from circle center to segment start
        let toStart = start - circle.center
        
        let dir = direction
        let dirSq = dir.magnitudeSquared()
        
        if dirSq == 0 {
            // Segment is a point, check if it's inside the circle
            // Directly compute distance using Int64
            let dx64 = Int64(toStart.x)
            let dy64 = Int64(toStart.y)
            let (distSqX, _) = dx64.multipliedReportingOverflow(by: dx64)
            let (distSqY, _) = dy64.multipliedReportingOverflow(by: dy64)
            let (distSq, _) = distSqX.addingReportingOverflow(distSqY)
            
            let (radiusSq, _) = circle.radius.multipliedReportingOverflow(by: circle.radius)
            if distSq <= radiusSq {
                return start
            }
            return nil
        }
        
        // Project circle center onto the line segment
        let projection = toStart.dot(dir)
        
        var t: Float
        if projection <= 0 {
            t = 0  // Closest point is start
        } else if projection >= dirSq {
            t = 1  // Closest point is end
        } else {
            t = Float(projection) / Float(dirSq)
        }
        
        // Calculate closest point on segment to circle center
        let closestPoint = IVec2(
            x: start.floatX + dir.floatX * t,
            y: start.floatY + dir.floatY * t
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
            // Return the closest point as intersection
            return closestPoint
        }
        
        if distSq > radiusSq {
            return nil  // Segment doesn't intersect circle
        }
        
        // Calculate actual intersection point(s)
        // Solve: ||start + t * dir - center|| = radius
        // This is a quadratic equation: a*t^2 + b*t + c = 0
        
        let a = dirSq
        let b = Int64(2) * toStart.dot(dir)
        let c = toStart.magnitudeSquared() - radiusSq
        
        // Discriminant
        let discriminant = b * b - Int64(4) * a * c
        
        if discriminant < 0 {
            return nil  // No real solutions
        }
        
        // Calculate t values
        let sqrtDisc = Int64(sqrt(Float(discriminant)))
        let t1 = Float(-b - sqrtDisc) / Float(Int64(2) * a)
        let t2 = Float(-b + sqrtDisc) / Float(Int64(2) * a)
        
        // Find the intersection point within the segment [0, 1]
        var intersectionT: Float? = nil
        
        if t1 >= 0 && t1 <= 1 {
            intersectionT = t1
        } else if t2 >= 0 && t2 <= 1 {
            intersectionT = t2
        }
        
        guard let t = intersectionT else {
            return nil  // No intersection within segment
        }
        
        // Calculate intersection point
        let point = IVec2(
            x: start.floatX + dir.floatX * t,
            y: start.floatY + dir.floatY * t
        )
        
        return point
    }
    
    /// Computes the closest point on this segment to a given point.
    ///
    /// - Parameter point: The point to find the closest point to.
    /// - Returns: The closest point on the segment.
    ///
    ///
    /// Example:
    /// ```swift
    /// let segment = ILineSegment(start: IVec2(x: 0.0, y: 0.0), end: IVec2(x: 1.0, y: 0.0))
    /// let closest = segment.closestPoint(to: IVec2(x: 0.5, y: 0.5))  // (0.5, 0.0)
    /// ```
    @inlinable
    public func closestPoint(to point: IVec2) -> IVec2 {
        let toStart = point - start
        let dir = direction
        let dirSq = dir.magnitudeSquared()
        
        if dirSq == 0 {
            return start  // Segment is a point
        }
        
        let t = toStart.dot(dir)
        
        if t <= 0 {
            return start
        }
        
        if t >= dirSq {
            return end
        }
        
        // Closest point is on the segment
        let tFloat = Float(t) / Float(dirSq)
        return IVec2(
            x: start.floatX + dir.floatX * tFloat,
            y: start.floatY + dir.floatY * tFloat
        )
    }
}

// MARK: - SchemaMetadataProvider

extension ILineSegment: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "start",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "end",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
