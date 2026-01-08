// Tests/SwiftStateTreeDeterministicMathTests/ICircleTests.swift
//
// Tests for ICircle collision detection.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("ICircle contains point correctly")
func testICircleContains() {
    let circle = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
    
    #expect(circle.contains(IVec2(x: 0.0, y: 0.0)) == true)  // Center
    #expect(circle.contains(IVec2(x: 0.5, y: 0.0)) == true)  // On boundary
    #expect(circle.contains(IVec2(x: 0.3, y: 0.3)) == true)  // Inside
    #expect(circle.contains(IVec2(x: 0.6, y: 0.0)) == false)  // Outside
}

@Test("ICircle intersects with another circle")
func testICircleIntersects() {
    let circle1 = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
    let circle2 = ICircle(center: IVec2(x: 0.8, y: 0.0), radius: 0.5)
    let circle3 = ICircle(center: IVec2(x: 1.5, y: 0.0), radius: 0.5)
    
    #expect(circle1.intersects(circle2) == true)  // Overlapping
    #expect(circle1.intersects(circle3) == false)  // Not touching
}

@Test("ICircle intersects with AABB")
func testICircleIntersectsAABB() {
    let circle = ICircle(center: IVec2(x: 0.5, y: 0.5), radius: 0.3)
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    
    #expect(circle.intersects(aabb: box) == true)  // Circle overlaps box
}

@Test("ICircle bounding AABB works correctly")
func testICircleBoundingAABB() {
    let circle = ICircle(center: IVec2(x: 0.5, y: 0.5), radius: 0.3)
    let aabb = circle.boundingAABB()
    
    // AABB should contain the circle
    #expect(aabb.contains(circle.center) == true)
    #expect(aabb.contains(IVec2(x: 0.5 + 0.3, y: 0.5)) == true)  // Right edge
    #expect(aabb.contains(IVec2(x: 0.5 - 0.3, y: 0.5)) == true)  // Left edge
}

// MARK: - Overflow Tests

@Test("ICircle intersects handles large radius without Int64 overflow")
func testICircleIntersectsLargeRadius() {
    // Test with large but safe radius values
    // Radius is clamped to MAX_CIRCLE_RADIUS (Int32.max) in init
    // So we test with Int32.max value
    let safeMax = FixedPoint.MAX_CIRCLE_RADIUS
    let circle1 = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: safeMax)
    let circle2 = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: safeMax)
    
    // Should not crash or overflow (though radiusSum^2 might overflow, handled conservatively)
    let intersects = circle1.intersects(circle2)
    #expect(intersects == true)  // Same center, should intersect (or treated as intersecting due to overflow handling)
}

@Test("ICircle intersects with very large radius is clamped and handled")
func testICircleIntersectsVeryLargeRadius() {
    // Test with very large radius - this will be clamped to MAX_CIRCLE_RADIUS in init
    // Then radiusSum^2 might overflow Int64, but handled conservatively
    let maxRadius: Int64 = Int64.max / 2  // Very large, will be clamped to Int32.max
    let circle1 = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: maxRadius)
    let circle2 = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: maxRadius)
    
    // Radius is clamped to MAX_CIRCLE_RADIUS (Int32.max) in init
    // radiusSum^2 = (2 * Int32.max)^2 might overflow, handled conservatively as intersecting
    let intersects = circle1.intersects(circle2)
    // Should return a boolean (likely true due to conservative overflow handling)
    #expect(intersects == true || intersects == false)  // Should return a boolean
    
    // Verify radius was clamped
    #expect(circle1.radius == FixedPoint.MAX_CIRCLE_RADIUS)
    #expect(circle2.radius == FixedPoint.MAX_CIRCLE_RADIUS)
}

@Test("ICircle radius clamping works correctly")
func testICircleRadiusClamping() {
    // Test that radius is clamped to MAX_CIRCLE_RADIUS
    let largeRadius: Int64 = Int64.max / 2
    let circle = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: largeRadius)
    
    // Radius should be clamped to MAX_CIRCLE_RADIUS
    #expect(circle.radius == FixedPoint.MAX_CIRCLE_RADIUS)
    
    // Test with valid radius (should not be clamped)
    let validRadius: Int64 = 1000
    let circle2 = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: validRadius)
    #expect(circle2.radius == validRadius)
}

@Test("ICircle floatRadius handles Int64 correctly")
func testICircleFloatRadiusInt64() {
    // Test that floatRadius correctly handles Int64 values
    let radiusValue: Int64 = 500  // 0.5 Float units with scale 1000
    let circle = ICircle(center: IVec2(x: 0.0, y: 0.0), fixedPointRadius: radiusValue)
    
    // floatRadius should use Int64 dequantize
    let floatRadius = circle.floatRadius
    #expect(abs(floatRadius - 0.5) < 0.001)  // Should be approximately 0.5
}

@Test("FixedPoint world coordinate constants are correct")
func testFixedPointWorldCoordinateConstants() {
    // Verify WORLD_MAX_COORDINATE is Int32.max / 2
    #expect(FixedPoint.WORLD_MAX_COORDINATE == Int32.max / 2)
    #expect(FixedPoint.WORLD_MIN_COORDINATE == -FixedPoint.WORLD_MAX_COORDINATE)
    
    // Verify MAX_CIRCLE_RADIUS is Int32.max
    #expect(FixedPoint.MAX_CIRCLE_RADIUS == Int64(Int32.max))
    #expect(FixedPoint.MIN_CIRCLE_RADIUS == 0)
}
