// Sources/SwiftStateTreeDeterministicMath/Collision/IAABB2.swift
//
// Integer axis-aligned bounding box (AABB) for 2D collision detection.
// All operations use integer arithmetic for deterministic behavior.

import Foundation
import SwiftStateTree

/// An axis-aligned bounding box (AABB) using integer coordinates.
///
/// This type is used for collision detection and spatial queries in deterministic
/// game logic. All operations use integer arithmetic to ensure consistency.
///
/// Example:
/// ```swift
/// let box = IAABB2(min: IVec2(x: 0, y: 0), max: IVec2(x: 1000, y: 1000))
/// let point = IVec2(x: 500, y: 500)
/// let contains = box.contains(point)  // true
/// ```
@SnapshotConvertible
public struct IAABB2: Codable, Equatable, Sendable {
    /// The minimum corner of the bounding box.
    public let min: IVec2
    
    /// The maximum corner of the bounding box.
    public let max: IVec2
    
    /// Creates a new IAABB2 with the given corners.
    ///
    /// - Parameters:
    ///   - min: The minimum corner.
    ///   - max: The maximum corner.
    ///
    /// Note: It is the caller's responsibility to ensure min <= max for each component.
    public init(min: IVec2, max: IVec2) {
        self.min = min
        self.max = max
    }
    
    /// Creates a new IAABB2 from a center point and size.
    ///
    /// - Parameters:
    ///   - center: The center point of the bounding box.
    ///   - size: The size of the bounding box (width, height).
    public init(center: IVec2, size: IVec2) {
        let halfSize = IVec2(fixedPointX: size.x / 2, fixedPointY: size.y / 2)
        self.min = center - halfSize
        self.max = center + halfSize
    }
    
    /// Checks if the bounding box contains a point.
    ///
    /// - Parameter point: The point to check.
    /// - Returns: `true` if the point is inside the bounding box (inclusive).
    public func contains(_ point: IVec2) -> Bool {
        point.x >= min.x && point.x <= max.x &&
        point.y >= min.y && point.y <= max.y
    }
    
    /// Checks if this bounding box intersects with another.
    ///
    /// - Parameter other: The other bounding box.
    /// - Returns: `true` if the bounding boxes intersect.
    public func intersects(_ other: IAABB2) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y
    }
    
    /// Expands the bounding box by a fixed amount on all sides.
    ///
    /// - Parameter amount: The amount to expand (same for all sides).
    /// - Returns: A new expanded bounding box.
    public func expanded(by amount: Int32) -> IAABB2 {
        IAABB2(
            min: IVec2(fixedPointX: min.x - amount, fixedPointY: min.y - amount),
            max: IVec2(fixedPointX: max.x + amount, fixedPointY: max.y + amount)
        )
    }
    
    /// Computes the union of this bounding box with another.
    ///
    /// - Parameter other: The other bounding box.
    /// - Returns: A new bounding box that contains both boxes.
    public func union(_ other: IAABB2) -> IAABB2 {
        IAABB2(
            min: IVec2(
                fixedPointX: Swift.min(min.x, other.min.x),
                fixedPointY: Swift.min(min.y, other.min.y)
            ),
            max: IVec2(
                fixedPointX: Swift.max(max.x, other.max.x),
                fixedPointY: Swift.max(max.y, other.max.y)
            )
        )
    }
    
    /// Clamps a point to be within the bounding box.
    ///
    /// - Parameter point: The point to clamp.
    /// - Returns: A new point clamped to the bounding box boundaries.
    public func clamp(_ point: IVec2) -> IVec2 {
        IVec2(
            fixedPointX: Swift.max(min.x, Swift.min(max.x, point.x)),
            fixedPointY: Swift.max(min.y, Swift.min(max.y, point.y))
        )
    }
    
    /// Computes the intersection of this bounding box with another.
    ///
    /// - Parameter other: The other bounding box.
    /// - Returns: The intersection bounding box, or `nil` if they don't intersect.
    ///
    /// Example:
    /// ```swift
    /// let box1 = IAABB2(min: IVec2(x: 0, y: 0), max: IVec2(x: 1000, y: 1000))
    /// let box2 = IAABB2(min: IVec2(x: 500, y: 500), max: IVec2(x: 1500, y: 1500))
    /// let intersection = box1.intersection(box2)  // IAABB2(min: (500, 500), max: (1000, 1000))
    /// ```
    public func intersection(_ other: IAABB2) -> IAABB2? {
        guard intersects(other) else {
            return nil
        }
        
        return IAABB2(
            min: IVec2(
                fixedPointX: Swift.max(min.x, other.min.x),
                fixedPointY: Swift.max(min.y, other.min.y)
            ),
            max: IVec2(
                fixedPointX: Swift.min(max.x, other.max.x),
                fixedPointY: Swift.min(max.y, other.max.y)
            )
        )
    }
    
    /// Computes the size of the bounding box.
    ///
    /// - Returns: The size as a vector (width, height).
    public func size() -> IVec2 {
        IVec2(fixedPointX: max.x - min.x, fixedPointY: max.y - min.y)
    }
    
    /// Computes the center point of the bounding box.
    ///
    /// - Returns: The center point.
    public func center() -> IVec2 {
        IVec2(
            fixedPointX: (min.x + max.x) / 2,
            fixedPointY: (min.y + max.y) / 2
        )
    }
    
    /// Computes the area of the bounding box.
    ///
    /// - Returns: The area (Int64 to handle overflow).
    public func area() -> Int64 {
        let size = self.size()
        return Int64(size.x) * Int64(size.y)
    }
}

// MARK: - SchemaMetadataProvider

extension IAABB2: SchemaMetadataProvider {
    /// Provides metadata for schema generation.
    public static func getFieldMetadata() -> [FieldMetadata] {
        [
            FieldMetadata(
                name: "min",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "max",
                type: IVec2.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            )
        ]
    }
}
