// Tests/SwiftStateTreeDeterministicMathTests/IAABB2Tests.swift
//
// Tests for IAABB2 collision detection.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IAABB2 contains point correctly")
func testIAABB2Contains() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    
    #expect(box.contains(IVec2(x: 0.5, y: 0.5)) == true)
    #expect(box.contains(IVec2(x: 0.0, y: 0.0)) == true)
    #expect(box.contains(IVec2(x: 1.0, y: 1.0)) == true)
    #expect(box.contains(IVec2(x: 1.5, y: 0.5)) == false)
    #expect(box.contains(IVec2(x: 0.5, y: 1.5)) == false)
}

@Test("IAABB2 intersects correctly")
func testIAABB2Intersects() {
    let box1 = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    let box2 = IAABB2(min: IVec2(x: 0.5, y: 0.5), max: IVec2(x: 1.5, y: 1.5))
    let box3 = IAABB2(min: IVec2(x: 2.0, y: 2.0), max: IVec2(x: 3.0, y: 3.0))
    
    #expect(box1.intersects(box2) == true)
    #expect(box1.intersects(box3) == false)
}

@Test("IAABB2 expanded works correctly")
func testIAABB2Expanded() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    // Use internal initializer for fixed-point amount (100 = 0.1 in fixed-point)
    let expanded = box.expanded(by: 100)
    
    #expect(expanded.min.x == -100)  // 0.0 - 0.1 = -0.1 -> -100
    #expect(expanded.min.y == -100)
    #expect(expanded.max.x == 1100)  // 1.0 + 0.1 = 1.1 -> 1100
    #expect(expanded.max.y == 1100)
}

@Test("IAABB2 clamp works correctly")
func testIAABB2Clamp() {
    let box = IAABB2(min: IVec2(x: 0.0, y: 0.0), max: IVec2(x: 1.0, y: 1.0))
    
    let inside = box.clamp(IVec2(x: 0.5, y: 0.5))
    #expect(inside.x == 500)  // 0.5 -> 500
    #expect(inside.y == 500)
    
    let outside = box.clamp(IVec2(x: 1.5, y: -0.1))
    #expect(outside.x == 1000)  // Clamped to 1.0 -> 1000
    #expect(outside.y == 0)  // Clamped to 0.0 -> 0
}
