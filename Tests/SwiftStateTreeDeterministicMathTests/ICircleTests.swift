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
