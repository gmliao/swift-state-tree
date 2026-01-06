// Tests/SwiftStateTreeDeterministicMathTests/IVec2VectorUtilsTests.swift
//
// Tests for IVec2 vector utility functions (cross, project, reflect).

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec2 cross product works correctly")
func testIVec2Cross() {
    let v1 = IVec2(x: 1.0, y: 0.0)
    let v2 = IVec2(x: 0.0, y: 1.0)
    
    let cross = v1.cross(v2)
    #expect(cross > 0)  // Should be positive (counterclockwise)
    
    let crossReverse = v2.cross(v1)
    #expect(crossReverse < 0)  // Should be negative (clockwise)
}

@Test("IVec2 project works correctly")
func testIVec2Project() {
    let v1 = IVec2(x: 1.0, y: 1.0)
    let v2 = IVec2(x: 1.0, y: 0.0)  // X-axis
    
    let proj = v1.project(onto: v2)
    // Projection should be (1.0, 0.0) since v1 has x-component 1.0
    #expect(abs(proj.x - 1000) < 100)
    #expect(abs(proj.y) < 100)
}

@Test("IVec2 reflect works correctly")
func testIVec2Reflect() {
    // Velocity moving down-right
    let velocity = IVec2(x: 1.0, y: -1.0)
    // Surface normal pointing up
    let normal = IVec2(x: 0.0, y: 1.0)
    
    let reflected = velocity.reflect(off: normal)
    // Should bounce up-right: (1.0, 1.0)
    #expect(abs(reflected.x - 1000) < 100)
    #expect(abs(reflected.y - 1000) < 100)
}
