// Tests/SwiftStateTreeDeterministicMathTests/IVec3MathTests.swift
//
// Tests for IVec3 game math operations (dot, cross, magnitude, distance).

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec3 dot product works correctly")
func testIVec3Dot() {
    let v1 = IVec3(x: 1.0, y: 2.0, z: 3.0)
    let v2 = IVec3(x: 0.5, y: 0.3, z: 0.1)
    let dot = v1.dot(v2)
    
    // 1000 * 500 + 2000 * 300 + 3000 * 100 = 500000 + 600000 + 300000 = 1400000
    #expect(dot == 1400000)
}

@Test("IVec3 cross product works correctly")
func testIVec3Cross() {
    // x-axis cross y-axis should give z-axis
    let v1 = IVec3(x: 1.0, y: 0.0, z: 0.0)  // x-axis
    let v2 = IVec3(x: 0.0, y: 1.0, z: 0.0)  // y-axis
    let cross = v1.cross(v2)
    
    // cross(x-axis, y-axis) = z-axis = (0, 0, 1000000)
    #expect(cross.x == 0)
    #expect(cross.y == 0)
    #expect(cross.z == 1000000)
}

@Test("IVec3 magnitudeSquared works correctly")
func testIVec3MagnitudeSquared() {
    let v = IVec3(x: 2.0, y: 3.0, z: 6.0)
    let magSq = v.magnitudeSquared()
    
    // 2000^2 + 3000^2 + 6000^2 = 4000000 + 9000000 + 36000000 = 49000000
    #expect(magSq == 49000000)
}

@Test("IVec3 distanceSquared works correctly")
func testIVec3DistanceSquared() {
    let v1 = IVec3(x: 1.0, y: 2.0, z: 3.0)
    let v2 = IVec3(x: 4.0, y: 6.0, z: 9.0)
    let distSq = v1.distanceSquared(to: v2)
    
    // (3000)^2 + (4000)^2 + (6000)^2 = 9000000 + 16000000 + 36000000 = 61000000
    #expect(distSq == 61000000)
}
