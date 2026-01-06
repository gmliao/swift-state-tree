// Tests/SwiftStateTreeDeterministicMathTests/IVec2MathTests.swift
//
// Tests for IVec2 game math operations (dot, magnitude, distance, angle, etc.).

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec2 dot product works correctly")
func testIVec2Dot() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 0.5, y: 0.3)
    let dot = v1.dot(v2)
    
    // 1000 * 500 + 2000 * 300 = 500000 + 600000 = 1100000
    #expect(dot == 1100000)
}

@Test("IVec2 magnitudeSquared works correctly")
func testIVec2MagnitudeSquared() {
    let v = IVec2(x: 3.0, y: 4.0)
    let magSq = v.magnitudeSquared()
    
    // 3000^2 + 4000^2 = 9000000 + 16000000 = 25000000
    #expect(magSq == 25000000)
}

@Test("IVec2 magnitude works correctly")
func testIVec2Magnitude() {
    let v = IVec2(x: 3.0, y: 4.0)  // (3.0, 4.0) after dequantization
    let mag = v.magnitude()
    
    // sqrt(3.0^2 + 4.0^2) = sqrt(9 + 16) = sqrt(25) = 5.0
    #expect(abs(mag - 5.0) < 0.01)
}

@Test("IVec2 distanceSquared works correctly")
func testIVec2DistanceSquared() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 4.0, y: 6.0)
    let distSq = v1.distanceSquared(to: v2)
    
    // (3000)^2 + (4000)^2 = 9000000 + 16000000 = 25000000
    #expect(distSq == 25000000)
}

@Test("IVec2 toAngle works correctly")
func testIVec2ToAngle() {
    // 45 degrees = π/4 radians
    let v = IVec2(x: 1.0, y: 1.0)  // (1.0, 1.0) after dequantization
    let angle = v.toAngle()
    
    // atan2(1.0, 1.0) ≈ 0.785 (π/4)
    #expect(abs(angle - Float.pi / 4) < 0.01)
}

@Test("IVec2 fromAngle works correctly")
func testIVec2FromAngle() {
    let angle = Float.pi / 4  // 45 degrees
    let magnitude: Float = 1.414  // sqrt(2)
    let v = IVec2.fromAngle(angle: angle, magnitude: magnitude)
    
    // cos(π/4) * 1.414 ≈ 1.0, sin(π/4) * 1.414 ≈ 1.0
    #expect(abs(v.floatX - 1.0) < 0.1)
    #expect(abs(v.floatY - 1.0) < 0.1)
}

@Test("IVec2 rotated90 works correctly")
func testIVec2Rotated90() {
    let v = IVec2(x: 1.0, y: 2.0)
    let rotated = v.rotated90()
    
    // Rotate 90° CCW: (x, y) -> (-y, x)
    #expect(rotated.x == -2000)  // -2.0 -> -2000
    #expect(rotated.y == 1000)  // 1.0 -> 1000
}

@Test("IVec2 rotatedMinus90 works correctly")
func testIVec2RotatedMinus90() {
    let v = IVec2(x: 1.0, y: 2.0)
    let rotated = v.rotatedMinus90()
    
    // Rotate -90° (90° CW): (x, y) -> (y, -x)
    #expect(rotated.x == 2000)  // 2.0 -> 2000
    #expect(rotated.y == -1000)  // -1.0 -> -1000
}
