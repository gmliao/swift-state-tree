// Tests/SwiftStateTreeDeterministicMathTests/AngleLerpTests.swift
//
// Tests for Angle.lerp to verify it doesn't have double-quantization issues.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("Angle.lerp interpolates correctly without double-quantization")
func testAngleLerpCorrect() {
    let from = Angle(degrees: 0.0)   // 0°
    let to = Angle(degrees: 90.0)    // 90°
    let t: Float = 0.5  // Should get 45°
    
    let result = Angle.lerp(from: from, to: to, t: t)
    
    // Should be approximately 45 degrees, not 45000 degrees!
    #expect(abs(result.floatDegrees - 45.0) < 0.1, 
        "Lerp from 0° to 90° at t=0.5 should give ~45°, got \(result.floatDegrees)°")
    
    // Raw value should be around 45000 (45 * 1000), not 45000000
    #expect(abs(result.degrees - 45000) < 1000,
        "Raw degrees should be ~45000, got \(result.degrees)")
}

@Test("Angle.lerp handles different interpolation factors")
func testAngleLerpDifferentFactors() {
    // Use smaller angle range to avoid shortestDifference normalization issues
    let from = Angle(degrees: 10.0)
    let to = Angle(degrees: 100.0)
    
    // At t=0.0, should be from (10°)
    let result0 = Angle.lerp(from: from, to: to, t: 0.0)
    #expect(abs(result0.floatDegrees - 10.0) < 0.1)
    
    // At t=1.0, should be to (100°)
    let result1 = Angle.lerp(from: from, to: to, t: 1.0)
    #expect(abs(result1.floatDegrees - 100.0) < 0.1)
    
    // At t=0.5, should be 55° (10 + (100-10)*0.5)
    let result2 = Angle.lerp(from: from, to: to, t: 0.5)
    #expect(abs(result2.floatDegrees - 55.0) < 0.1)
}
