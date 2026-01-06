// Tests/SwiftStateTreeDeterministicMathTests/FixedPointTests.swift
//
// Tests for FixedPoint quantization and dequantization functions.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("FixedPoint quantize converts Float to Int32 correctly")
func testQuantize() {
    // Test basic quantization
    #expect(FixedPoint.quantize(1.0) == 1000)
    #expect(FixedPoint.quantize(0.5) == 500)
    #expect(FixedPoint.quantize(2.5) == 2500)
    #expect(FixedPoint.quantize(0.0) == 0)
    #expect(FixedPoint.quantize(-1.0) == -1000)
}

@Test("FixedPoint dequantize converts Int32 to Float correctly")
func testDequantize() {
    // Test basic dequantization
    #expect(FixedPoint.dequantize(1000) == 1.0)
    #expect(FixedPoint.dequantize(500) == 0.5)
    #expect(FixedPoint.dequantize(2500) == 2.5)
    #expect(FixedPoint.dequantize(0) == 0.0)
    #expect(FixedPoint.dequantize(-1000) == -1.0)
}

@Test("FixedPoint quantize and dequantize are inverse operations")
func testQuantizeDequantizeRoundTrip() {
    let testValues: [Float] = [0.0, 0.5, 1.0, 1.5, 2.0, -1.0, -0.5, 100.0, -100.0]
    
    for value in testValues {
        let quantized = FixedPoint.quantize(value)
        let dequantized = FixedPoint.dequantize(quantized)
        // Allow small floating-point error
        #expect(abs(dequantized - value) < 0.001)
    }
}

@Test("FixedPoint handles extreme values")
func testExtremeValues() {
    // Test with very large values
    let largeValue: Float = 1000000.0
    let quantized = FixedPoint.quantize(largeValue)
    #expect(quantized == 1000000000)  // 1000000 * 1000
    
    // Test with very small values
    let smallValue: Float = 0.001
    let quantizedSmall = FixedPoint.quantize(smallValue)
    #expect(quantizedSmall == 1)  // 0.001 * 1000 = 1
    
    // Test with negative extreme values
    let negativeLarge: Float = -1000000.0
    let quantizedNegative = FixedPoint.quantize(negativeLarge)
    #expect(quantizedNegative == -1000000000)
}

@Test("FixedPoint uses .toNearestOrAwayFromZero rounding rule")
func testRoundingRule() {
    // Test .toNearestOrAwayFromZero (fixed rounding rule)
    // Positive values round away from zero
    #expect(FixedPoint.quantize(1.1) == 1100)
    #expect(FixedPoint.quantize(1.4) == 1400)
    #expect(FixedPoint.quantize(1.5) == 1500)  // Half value rounds away from zero
    #expect(FixedPoint.quantize(1.6) == 1600)
    #expect(FixedPoint.quantize(2.5) == 2500)  // Half value rounds away from zero
    
    // Negative values round away from zero
    #expect(FixedPoint.quantize(-1.1) == -1100)
    #expect(FixedPoint.quantize(-1.4) == -1400)
    #expect(FixedPoint.quantize(-1.5) == -1500)  // Half value rounds away from zero
    #expect(FixedPoint.quantize(-1.6) == -1600)
    #expect(FixedPoint.quantize(-2.5) == -2500)  // Half value rounds away from zero
    
    // Test edge cases
    #expect(FixedPoint.quantize(0.0) == 0)
    #expect(FixedPoint.quantize(0.5) == 500)  // Rounds to 500 (away from zero)
    #expect(FixedPoint.quantize(-0.5) == -500)  // Rounds to -500 (away from zero)
}

@Test("FixedPoint clampToInt32Range prevents overflow")
func testClampToInt32Range() {
    // Test with values within range
    let normalValue: Float = 1000.0
    #expect(FixedPoint.clampToInt32Range(normalValue) == 1000.0)
    
    // Test with values exceeding Int32.max / scale
    let maxValue = Float(Int32.max) / Float(FixedPoint.scale)
    let exceededValue = maxValue * 2.0
    let clamped = FixedPoint.clampToInt32Range(exceededValue)
    #expect(clamped <= maxValue)
    
    // Test with values below Int32.min / scale
    let minValue = Float(Int32.min) / Float(FixedPoint.scale)
    let belowValue = minValue * 2.0
    let clampedBelow = FixedPoint.clampToInt32Range(belowValue)
    #expect(clampedBelow >= minValue)
}
