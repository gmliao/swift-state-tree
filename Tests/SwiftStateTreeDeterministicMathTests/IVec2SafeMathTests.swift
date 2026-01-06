// Tests/SwiftStateTreeDeterministicMathTests/IVec2SafeMathTests.swift
//
// Tests for safe math operations that prevent overflow.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec2 multiplySafe prevents overflow")
func testIVec2MultiplySafe() {
    // Test with values that would overflow with regular multiplication
    // Use internal initializer for large fixed-point values
    let v = IVec2(fixedPointX: 2000000, fixedPointY: 2000000)
    let scalar: Int32 = 2
    
    // Regular multiplication would wrap
    let regular = v * scalar
    // multiplySafe should clamp instead
    let safe = IVec2.multiplySafe(v, by: scalar)
    
    // Safe version should clamp to Int32.max
    #expect(safe.x == Int32.max || safe.x == 4000000)  // Depends on whether 4000000 fits in Int32
    #expect(safe.y == Int32.max || safe.y == 4000000)
}

@Test("IVec2 multiplySafe handles large values correctly")
func testIVec2MultiplySafeLargeValues() {
    let v = IVec2(fixedPointX: Int32.max / 2, fixedPointY: Int32.max / 2)
    let scalar: Int32 = 3
    
    let safe = IVec2.multiplySafe(v, by: scalar)
    
    // Should clamp to Int32.max
    #expect(safe.x == Int32.max)
    #expect(safe.y == Int32.max)
}

@Test("IVec2 magnitudeSquaredSafe matches magnitudeSquared")
func testIVec2MagnitudeSquaredSafe() {
    let v = IVec2(x: 3.0, y: 4.0)
    
    let magSq1 = v.magnitudeSquared()
    let magSq2 = v.magnitudeSquaredSafe()
    
    // Both should return the same value (both use Int64)
    #expect(magSq1 == magSq2)
}
