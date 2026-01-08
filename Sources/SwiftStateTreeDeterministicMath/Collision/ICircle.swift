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
    /// Uses Int64 to support larger radius values while maintaining safety.
    public let radius: Int64
    
    /// Creates a new ICircle with the given center and radius.
    ///
    /// - Parameters:
    ///   - center: The center point of the circle.
    ///   - radius: The radius as a Float (will be quantized and clamped to MAX_CIRCLE_RADIUS).
    ///
    /// **Invariant:** The radius will be clamped to `FixedPoint.MAX_CIRCLE_RADIUS` to ensure
    /// compatibility with `boundingAABB()` and other Int32-based operations.
    ///
    /// Example:
    /// ```swift
    /// let circle = ICircle(center: IVec2(x: 1.0, y: 2.0), radius: 0.5)
    /// ```
    public init(center: IVec2, radius: Float) {
        self.center = center
        let quantized = Int64(FixedPoint.quantize(radius))
        self.radius = FixedPoint.clampCircleRadius(quantized)
    }
    
    /// Creates a new ICircle with the given center and fixed-point radius.
    ///
    /// - Parameters:
    ///   - center: The center point of the circle.
    ///   - fixedPointRadius: The radius as a fixed-point integer (will be clamped to MAX_CIRCLE_RADIUS).
    ///
    /// **Invariant:** The radius will be clamped to `FixedPoint.MAX_CIRCLE_RADIUS` to ensure
    /// compatibility with `boundingAABB()` and other Int32-based operations.
    ///
    /// This is an internal initializer for performance-critical code.
    @inlinable
    internal init(center: IVec2, fixedPointRadius: Int64) {
        self.center = center
        self.radius = FixedPoint.clampCircleRadius(fixedPointRadius)
    }
    
    /// The radius as a Float (dequantized).
    ///
    /// Uses Int64 dequantize to support values beyond Int32 range.
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
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` to prevent `Int64` overflow.
    /// - **Radius:** Must be within `FixedPoint.MAX_CIRCLE_RADIUS` to ensure compatibility.
    @inlinable
    public func contains(_ point: IVec2) -> Bool {
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(center.x) - Int64(point.x)
        let dy64 = Int64(center.y) - Int64(point.y)
        
        // Check for potential overflow in distance calculation
        let (distSqX, distOverflowX) = dx64.multipliedReportingOverflow(by: dx64)
        if distOverflowX {
            return false  // Point is extremely far away, outside circle
        }
        let (distSqY, distOverflowY) = dy64.multipliedReportingOverflow(by: dy64)
        if distOverflowY {
            return false
        }
        let (distSq, distOverflow) = distSqX.addingReportingOverflow(distSqY)
        if distOverflow {
            return false
        }
        
        let (radiusSq, radiusOverflow) = radius.multipliedReportingOverflow(by: radius)
        if radiusOverflow {
            // If radius squared overflows, treat as always containing (conservative)
            return true
        }
        
        return distSq <= radiusSq
    }
    
    /// Checks if this circle intersects with another circle.
    ///
    /// - Parameter other: The other circle.
    /// - Returns: `true` if the circles intersect (touch or overlap).
    ///
    /// Uses squared distance comparison to avoid floating-point operations.
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` (≈ ±1,073,741,823 fixed-point units,
    ///   or ±1,073,741.823 Float units with scale 1000) to prevent `Int64` overflow in `dx² + dy²`.
    ///   This ensures `|dx| ≤ Int32.max / 2`, so `dx² ≤ (Int32.max / 2)²`, and `dx² + dy² ≤ Int64.max`.
    /// - **Radius:** Must be within `FixedPoint.MAX_CIRCLE_RADIUS` (≈ 2,147,483,647 fixed-point units,
    ///   or 2,147,483.647 Float units with scale 1000) to ensure compatibility with `boundingAABB()`
    ///   and other Int32-based operations.
    ///
    /// **Overflow Handling:** If `(radius + other.radius)²` would overflow `Int64`, the result
    /// is clamped to `Int64.max`, which effectively treats the circles as always intersecting.
    ///
    /// Example:
    /// ```swift
    /// let c1 = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
    /// let c2 = ICircle(center: IVec2(x: 0.8, y: 0.0), radius: 0.5)
    /// let intersects = c1.intersects(c2)  // true (overlapping)
    /// ```
    @inlinable
    public func intersects(_ other: ICircle) -> Bool {
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(center.x) - Int64(other.center.x)
        let dy64 = Int64(center.y) - Int64(other.center.y)
        
        // Check for potential overflow in distance calculation
        // Since coordinates are clamped to WORLD_MAX_COORDINATE, dx and dy are at most Int32.max / 2,
        // so dx² and dy² are at most (Int32.max / 2)², and dx² + dy² ≤ Int64.max
        let (distSq, distOverflow) = dx64.multipliedReportingOverflow(by: dx64)
        if distOverflow {
            // If dx² overflows, circles are extremely far apart, no intersection
            return false
        }
        let (distSq2, distOverflow2) = dy64.multipliedReportingOverflow(by: dy64)
        if distOverflow2 {
            return false
        }
        let (distSqSum, distOverflowSum) = distSq.addingReportingOverflow(distSq2)
        if distOverflowSum {
            return false
        }
        
        // Check for potential overflow in radius sum calculation
        let (radiusSum, radiusOverflow) = radius.addingReportingOverflow(other.radius)
        if radiusOverflow {
            // If radius sum overflows, treat as always intersecting (conservative)
            return true
        }
        let (radiusSumSq, radiusOverflowSq) = radiusSum.multipliedReportingOverflow(by: radiusSum)
        if radiusOverflowSq {
            // If radius sum squared overflows, treat as always intersecting (conservative)
            return true
        }
        
        return distSqSum <= radiusSumSq
    }
    
    /// Checks if this circle intersects with an AABB.
    ///
    /// - Parameter aabb: The axis-aligned bounding box.
    /// - Returns: `true` if the circle intersects with the AABB.
    ///
    /// This uses the closest point on the AABB to the circle center,
    /// then checks if that point is within the circle radius.
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` to prevent `Int64` overflow.
    /// - **Radius:** Must be within `FixedPoint.MAX_CIRCLE_RADIUS` to ensure compatibility.
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
        
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(center.x) - Int64(closestPoint.x)
        let dy64 = Int64(center.y) - Int64(closestPoint.y)
        
        // Check for potential overflow in distance calculation
        let (distSqX, distOverflowX) = dx64.multipliedReportingOverflow(by: dx64)
        if distOverflowX {
            return false
        }
        let (distSqY, distOverflowY) = dy64.multipliedReportingOverflow(by: dy64)
        if distOverflowY {
            return false
        }
        let (distSq, distOverflow) = distSqX.addingReportingOverflow(distSqY)
        if distOverflow {
            return false
        }
        
        let (radiusSq, radiusOverflow) = radius.multipliedReportingOverflow(by: radius)
        if radiusOverflow {
            // If radius squared overflows, treat as always intersecting (conservative)
            return true
        }
        
        return distSq <= radiusSq
    }
    
    /// Computes the squared distance from a point to the circle boundary.
    ///
    /// - Parameter point: The point to measure from.
    /// - Returns: The squared distance. Negative if the point is inside the circle.
    ///
    /// This is useful for collision detection and spatial queries.
    /// Directly computes distance using Int64 to avoid Int32 overflow issues.
    ///
    /// **Range Limits (Invariants):**
    /// - **Coordinates:** Must be within `FixedPoint.WORLD_MAX_COORDINATE` to prevent `Int64` overflow.
    /// - **Radius:** Must be within `FixedPoint.MAX_CIRCLE_RADIUS` to ensure compatibility.
    ///
    /// **Overflow Handling:** If overflow occurs, returns `Int64.max` as a conservative estimate.
    @inlinable
    public func distanceSquaredToBoundary(from point: IVec2) -> Int64 {
        // Directly compute distance using Int64 to avoid Int32 overflow
        let dx64 = Int64(center.x) - Int64(point.x)
        let dy64 = Int64(center.y) - Int64(point.y)
        
        // Check for potential overflow in distance calculation
        let (distSqX, distOverflowX) = dx64.multipliedReportingOverflow(by: dx64)
        if distOverflowX {
            return Int64.max  // Conservative: treat as very far away
        }
        let (distSqY, distOverflowY) = dy64.multipliedReportingOverflow(by: dy64)
        if distOverflowY {
            return Int64.max
        }
        let (distSq, distOverflow) = distSqX.addingReportingOverflow(distSqY)
        if distOverflow {
            return Int64.max
        }
        
        let (radiusSq, radiusOverflow) = radius.multipliedReportingOverflow(by: radius)
        if radiusOverflow {
            // If radius squared overflows, return negative value (conservative: treat as inside)
            return distSq >= Int64.max / 2 ? Int64.max : distSq - Int64.max
        }
        
        let (result, resultOverflow) = distSq.subtractingReportingOverflow(radiusSq)
        if resultOverflow {
            // If subtraction overflows, return Int64.min (point is very far inside)
            return Int64.min
        }
        
        return result
    }
    
    /// Computes the bounding AABB of this circle.
    ///
    /// - Returns: An AABB that fully contains the circle.
    ///
    ///
    /// **Invariant:** Since `radius` is clamped to `FixedPoint.MAX_CIRCLE_RADIUS` (Int32.max)
    /// in the initializer, it is guaranteed to be within Int32 range, so this conversion is safe.
    ///
    /// Example:
    /// ```swift
    /// let circle = ICircle(center: IVec2(x: 0.5, y: 0.5), radius: 0.3)
    /// let aabb = circle.boundingAABB()
    /// // aabb.min ≈ (0.2, 0.2), aabb.max ≈ (0.8, 0.8)
    /// ```
    @inlinable
    public func boundingAABB() -> IAABB2 {
        // Since radius is clamped to MAX_CIRCLE_RADIUS (Int32.max) in init,
        // this conversion is guaranteed to be safe and within Int32 range
        let radiusInt32 = Int32(radius)  // Safe: radius ≤ Int32.max
        let radiusVec = IVec2(fixedPointX: radiusInt32, fixedPointY: radiusInt32)
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
                type: Int64.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
