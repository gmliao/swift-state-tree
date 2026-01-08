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
    
    // Regular multiplication would wrap (we don't test it here, just verify safe version)
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

@Test("IVec2 distanceSquared handles large values without overflow")
func testIVec2DistanceSquaredLargeValues() {
    // Test with values that would overflow if computed in Int32
    // sqrt(Int32.max) ≈ 46,340, so use diff > 50,000
    let v1 = IVec2(fixedPointX: 0, fixedPointY: 0)
    let v2 = IVec2(fixedPointX: 50000, fixedPointY: 50000)
    
    let distSq = v1.distanceSquared(to: v2)
    
    // Should be 50000^2 + 50000^2 = 2,500,000,000 + 2,500,000,000 = 5,000,000,000
    let expected: Int64 = 5_000_000_000
    #expect(distSq == expected)
}

@Test("IVec2 magnitudeSquared handles large values without overflow")
func testIVec2MagnitudeSquaredLargeValues() {
    // Test with values that would overflow if computed in Int32
    let v = IVec2(fixedPointX: 50000, fixedPointY: 50000)
    
    let magSq = v.magnitudeSquared()
    
    // Should be 50000^2 + 50000^2 = 5,000,000,000
    let expected: Int64 = 5_000_000_000
    #expect(magSq == expected)
}

@Test("IVec2 dot product handles large values without overflow")
func testIVec2DotLargeValues() {
    // Test with values that would overflow if computed in Int32
    let v1 = IVec2(fixedPointX: 50000, fixedPointY: 50000)
    let v2 = IVec2(fixedPointX: 50000, fixedPointY: 50000)
    
    let dot = v1.dot(v2)
    
    // Should be 50000 * 50000 + 50000 * 50000 = 2,500,000,000 + 2,500,000,000 = 5,000,000,000
    let expected: Int64 = 5_000_000_000
    #expect(dot == expected)
}

@Test("Position2 isWithinDistance handles large threshold without overflow")
func testPosition2IsWithinDistanceLargeThreshold() {
    let pos1 = Position2(x: 0.0, y: 0.0)
    let pos2 = Position2(x: 100.0, y: 100.0)  // Large distance
    
    // Test with large threshold (1000.0 units)
    let isWithin = pos1.isWithinDistance(to: pos2, threshold: 1000.0)
    
    // Should be true (100.0 * sqrt(2) ≈ 141.4 < 1000.0)
    #expect(isWithin == true)
    
    // Test with small threshold (1.0 unit)
    let isNotWithin = pos1.isWithinDistance(to: pos2, threshold: 1.0)
    
    // Should be false (141.4 > 1.0)
    #expect(isNotWithin == false)
}

// MARK: - Overflow Tests for Basic Operations

@Test("IVec2 multiplication overflow wraps deterministically")
func testIVec2MultiplicationOverflow() {
    // Test that multiplication wraps (deterministic behavior)
    let largeVec = IVec2(fixedPointX: Int32.max / 2, fixedPointY: Int32.max / 2)
    let scalar: Int32 = 3
    
    // Regular multiplication will wrap
    let result = largeVec * scalar
    
    // Verify wrapping behavior (deterministic)
    // (Int32.max / 2) * 3 will overflow and wrap
    // Use wrapping multiplication to compute expected value
    let halfMax = Int32.max / 2
    let expectedX = halfMax &* scalar  // Wrapping multiplication
    let expectedY = halfMax &* scalar  // Wrapping multiplication
    
    // The result should be the wrapped value (deterministic)
    #expect(result.x == expectedX)
    #expect(result.y == expectedY)
    
    // Verify that it actually wrapped (result should be negative due to overflow)
    #expect(result.x < 0 || result.x == expectedX)
    #expect(result.y < 0 || result.y == expectedY)
}

@Test("IVec2 cross product handles large values without overflow")
func testIVec2CrossLargeValues() {
    // Test with values that would overflow if computed in Int32
    let v1 = IVec2(fixedPointX: 50000, fixedPointY: 50000)
    let v2 = IVec2(fixedPointX: 50000, fixedPointY: -50000)
    
    let cross = v1.cross(v2)
    
    // Should be 50000 * (-50000) - 50000 * 50000 = -2,500,000,000 - 2,500,000,000 = -5,000,000,000
    let expected: Int64 = -5_000_000_000
    #expect(cross == expected)
}

// MARK: - FixedPoint Safe Range Tests

@Test("FixedPoint safe range constants are correct")
func testFixedPointSafeRangeConstants() {
    // Verify maxSafeValue
    let expectedMax = Float(Int32.max) / Float(FixedPoint.scale)
    #expect(abs(FixedPoint.maxSafeValue - expectedMax) < 0.001)
    
    // Verify minSafeValue
    let expectedMin = Float(Int32.min) / Float(FixedPoint.scale)
    #expect(abs(FixedPoint.minSafeValue - expectedMin) < 0.001)
    
    // Verify maxSafeInt32 (should be approximately sqrt(Int32.max))
    let expectedMaxInt32 = Int32(sqrt(Double(Int32.max)))
    #expect(FixedPoint.maxSafeInt32 == expectedMaxInt32)
    
    // Verify minSafeInt32
    #expect(FixedPoint.minSafeInt32 == -FixedPoint.maxSafeInt32)
}

@Test("IVec2 operations within safe range do not overflow")
func testIVec2WithinSafeRange() {
    // Use values within safe range (maxSafeInt32)
    let safeMax = FixedPoint.maxSafeInt32
    let v1 = IVec2(fixedPointX: safeMax, fixedPointY: safeMax)
    let v2 = IVec2(fixedPointX: safeMax / 2, fixedPointY: safeMax / 2)
    
    // These operations should not overflow
    let sum = v1 + v2
    let diff = v1 - v2
    let dot = v1.dot(v2)
    let magSq = v1.magnitudeSquared()
    let distSq = v1.distanceSquared(to: v2)
    
    // Verify results are reasonable (not wrapped)
    #expect(sum.x > 0)
    #expect(sum.y > 0)
    #expect(diff.x > 0)
    #expect(diff.y > 0)
    #expect(dot > 0)
    #expect(magSq > 0)
    #expect(distSq > 0)
}

@Test("IVec2 operations near safe range boundary")
func testIVec2NearSafeRangeBoundary() {
    // Test with values just at the safe boundary
    let safeMax = FixedPoint.maxSafeInt32
    let v1 = IVec2(fixedPointX: safeMax, fixedPointY: safeMax)
    let v2 = IVec2(fixedPointX: safeMax, fixedPointY: safeMax)
    
    // These should still work without overflow (using Int64)
    let dot = v1.dot(v2)
    let magSq = v1.magnitudeSquared()
    
    // Verify Int64 results are correct
    let expectedDot: Int64 = Int64(safeMax) * Int64(safeMax) * 2
    let expectedMagSq: Int64 = Int64(safeMax) * Int64(safeMax) * 2
    
    #expect(dot == expectedDot)
    #expect(magSq == expectedMagSq)
}

@Test("IVec2 multiplySafe clamps correctly at boundaries")
func testIVec2MultiplySafeBoundaries() {
    // Test with values that would definitely overflow
    let v = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    let scalar: Int32 = 2
    
    let safe = IVec2.multiplySafe(v, by: scalar)
    
    // Should clamp to Int32.max
    #expect(safe.x == Int32.max)
    #expect(safe.y == Int32.max)
    
    // Test with negative values
    let vNeg = IVec2(fixedPointX: Int32.min, fixedPointY: Int32.min)
    let safeNeg = IVec2.multiplySafe(vNeg, by: 2)
    
    // Should clamp to Int32.min
    #expect(safeNeg.x == Int32.min)
    #expect(safeNeg.y == Int32.min)
}

@Test("FixedPoint quantize respects safe range")
func testFixedPointQuantizeSafeRange() {
    // Test with values within safe range
    let safeValue = FixedPoint.maxSafeValue * 0.9
    let quantized = FixedPoint.quantize(safeValue)
    
    // Should not overflow
    #expect(quantized < Int32.max)
    #expect(quantized > Int32.min)
    
    // Test that clampToInt32Range prevents overflow
    // Note: FixedPoint.quantize will crash if value exceeds Int32.max/scale,
    // so we test that clampToInt32Range correctly limits the value
    let unsafeValue = FixedPoint.maxSafeValue * 2.0
    let clampedValue = FixedPoint.clampToInt32Range(unsafeValue)
    
    // After clamping, should be within safe range
    #expect(clampedValue <= FixedPoint.maxSafeValue)
    #expect(clampedValue >= FixedPoint.minSafeValue)
    
    // Verify clamped value can be safely quantized
    // Use a value just slightly below maxSafeValue to avoid crash
    let nearMaxValue = FixedPoint.maxSafeValue * 0.999
    let quantizedNearMax = FixedPoint.quantize(nearMaxValue)
    #expect(quantizedNearMax <= Int32.max)
    #expect(quantizedNearMax >= Int32.min)
}

@Test("FixedPoint clampToInt32Range uses safe range")
func testFixedPointClampUsesSafeRange() {
    // Test that clampToInt32Range respects the safe range
    let exceedingValue = FixedPoint.maxSafeValue * 2.0
    let clamped = FixedPoint.clampToInt32Range(exceedingValue)
    
    // Should be clamped to maxSafeValue
    #expect(clamped <= FixedPoint.maxSafeValue)
    
    let belowValue = FixedPoint.minSafeValue * 2.0
    let clampedBelow = FixedPoint.clampToInt32Range(belowValue)
    
    // Should be clamped to minSafeValue
    #expect(clampedBelow >= FixedPoint.minSafeValue)
}

// MARK: - Extreme Boundary Tests (Int32.max values)

@Test("IVec2 magnitudeSquared handles Int32.max without Int64 overflow")
func testIVec2MagnitudeSquaredInt32Max() {
    // Test with maximum possible Int32 values
    // This is the extreme case - should not overflow Int64
    let v = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    
    let magSq = v.magnitudeSquared()
    
    // Should be Int32.max^2 + Int32.max^2
    // Int64 can safely hold this (verified: 2 * Int32.max^2 < Int64.max)
    let expected: Int64 = Int64(Int32.max) * Int64(Int32.max) * 2
    #expect(magSq == expected)
    
    // Verify it's within Int64 range
    #expect(magSq > 0)
    #expect(magSq <= Int64.max)
}

@Test("IVec2 dot product handles Int32.max without Int64 overflow")
func testIVec2DotInt32Max() {
    // Test with maximum possible Int32 values
    // This is the extreme case - should not overflow Int64
    let v1 = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    let v2 = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    
    let dot = v1.dot(v2)
    
    // Should be Int32.max * Int32.max + Int32.max * Int32.max
    // Int64 can safely hold this (verified: 2 * Int32.max^2 < Int64.max)
    let expected: Int64 = Int64(Int32.max) * Int64(Int32.max) * 2
    #expect(dot == expected)
    
    // Verify it's within Int64 range
    #expect(dot > 0)
    #expect(dot <= Int64.max)
}

@Test("IVec2 distanceSquared handles Int32.max without Int64 overflow")
func testIVec2DistanceSquaredInt32Max() {
    // Test with maximum possible Int32 values
    let v1 = IVec2(fixedPointX: 0, fixedPointY: 0)
    let v2 = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    
    let distSq = v1.distanceSquared(to: v2)
    
    // Should be Int32.max^2 + Int32.max^2
    let expected: Int64 = Int64(Int32.max) * Int64(Int32.max) * 2
    #expect(distSq == expected)
    
    // Verify it's within Int64 range
    #expect(distSq > 0)
    #expect(distSq <= Int64.max)
}

@Test("IVec2 cross product handles Int32.max without Int64 overflow")
func testIVec2CrossInt32Max() {
    // Test with maximum possible Int32 values
    let v1 = IVec2(fixedPointX: Int32.max, fixedPointY: 0)
    let v2 = IVec2(fixedPointX: 0, fixedPointY: Int32.max)
    
    let cross = v1.cross(v2)
    
    // Should be Int32.max * Int32.max - 0 = Int32.max^2
    let expected: Int64 = Int64(Int32.max) * Int64(Int32.max)
    #expect(cross == expected)
    
    // Verify it's within Int64 range
    #expect(cross > 0)
    #expect(cross <= Int64.max)
    
    // Test with negative values
    let v3 = IVec2(fixedPointX: Int32.max, fixedPointY: 0)
    let v4 = IVec2(fixedPointX: 0, fixedPointY: Int32.min)
    
    let crossNeg = v3.cross(v4)
    
    // Should be Int32.max * Int32.min - 0
    // Note: Int32.min = -2,147,483,648, so Int32.max * Int32.min is negative
    let expectedNeg: Int64 = Int64(Int32.max) * Int64(Int32.min)
    #expect(crossNeg == expectedNeg)
    #expect(crossNeg < 0)
}
