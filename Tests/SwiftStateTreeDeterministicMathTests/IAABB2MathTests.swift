// Tests/SwiftStateTreeDeterministicMathTests/IAABB2MathTests.swift
//
// Tests for IAABB2 math operations (intersection, size, center, area).

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IAABB2 intersection works correctly")
func testIAABB2Intersection() {
    let box1 = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    let box2 = IAABB2(min: IVec2(x: 0.5, y: 0.5), max: IVec2(x: 1.5, y: 1.5))
    let intersection = box1.intersection(box2)
    
    #expect(intersection != nil)
    #expect(intersection?.min.x == 500)  // 0.5 -> 500
    #expect(intersection?.min.y == 500)
    #expect(intersection?.max.x == 1000)  // 1.0 -> 1000
    #expect(intersection?.max.y == 1000)
}

@Test("IAABB2 intersection returns nil when boxes don't intersect")
func testIAABB2IntersectionNil() {
    let box1 = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    let box2 = IAABB2(min: IVec2(x: 2.0, y: 2.0), max: IVec2(x: 3.0, y: 3.0))
    let intersection = box1.intersection(box2)
    
    #expect(intersection == nil)
}

@Test("IAABB2 size works correctly")
func testIAABB2Size() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 2.0))
    let size = box.size()
    
    #expect(size.x == 1000)  // 1.0 -> 1000
    #expect(size.y == 2000)  // 2.0 -> 2000
}

@Test("IAABB2 center works correctly")
func testIAABB2Center() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 2.0))
    let center = box.center()
    
    #expect(center.x == 500)  // (0.0 + 1.0) / 2 = 0.5 -> 500
    #expect(center.y == 1000)  // (0.0 + 2.0) / 2 = 1.0 -> 1000
}

@Test("IAABB2 area works correctly")
func testIAABB2Area() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 2.0))
    let area = box.area()
    
    // 1000 * 2000 = 2000000
    #expect(area == 2000000)
}
