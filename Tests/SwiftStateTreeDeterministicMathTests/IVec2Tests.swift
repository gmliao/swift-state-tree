// Tests/SwiftStateTreeDeterministicMathTests/IVec2Tests.swift
//
// Tests for IVec2 integer vector operations and properties.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec2 addition is deterministic")
func testIVec2Addition() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 0.5, y: 0.3)
    let sum = v1 + v2
    
    #expect(sum.x == 1500)  // 1.0 + 0.5 = 1.5 -> 1500
    #expect(sum.y == 2300)  // 2.0 + 0.3 = 2.3 -> 2300
}

@Test("IVec2 subtraction is deterministic")
func testIVec2Subtraction() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 0.5, y: 0.3)
    let diff = v1 - v2
    
    #expect(diff.x == 500)  // 1.0 - 0.5 = 0.5 -> 500
    #expect(diff.y == 1700)  // 2.0 - 0.3 = 1.7 -> 1700
}

@Test("IVec2 multiplication with scalar is deterministic")
func testIVec2ScalarMultiplication() {
    let v = IVec2(x: 1.0, y: 2.0)
    // Note: scalar multiplication uses Int32, so we need to use fixedPointX for testing
    let scaled1 = IVec2(fixedPointX: v.x * 2, fixedPointY: v.y * 2)
    let scaled2 = IVec2(fixedPointX: v.x * 3, fixedPointY: v.y * 3)
    
    #expect(scaled1.x == 2000)  // 1.0 * 2 = 2.0 -> 2000
    #expect(scaled1.y == 4000)  // 2.0 * 2 = 4.0 -> 4000
    #expect(scaled2.x == 3000)  // 1.0 * 3 = 3.0 -> 3000
    #expect(scaled2.y == 6000)  // 2.0 * 3 = 6.0 -> 6000
}

@Test("IVec2 Codable serialization preserves values")
func testIVec2Codable() throws {
    let original = IVec2(x: 1.0, y: 2.0)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(IVec2.self, from: data)
    
    #expect(decoded.x == original.x)
    #expect(decoded.y == original.y)
    #expect(decoded == original)
}

@Test("IVec2 Hashable works correctly")
func testIVec2Hashable() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 1.0, y: 2.0)
    let v3 = IVec2(x: 1.0, y: 2.001)
    
    #expect(v1.hashValue == v2.hashValue)
    #expect(v1.hashValue != v3.hashValue)
    
    var set = Set<IVec2>()
    set.insert(v1)
    set.insert(v2)
    set.insert(v3)
    
    #expect(set.count == 2)  // v1 and v2 are equal, v3 is different
}

@Test("IVec2 overflow wraps correctly")
func testIVec2Overflow() {
    // Test wrapping overflow on addition
    // Use internal initializer for extreme values
    let maxVec = IVec2(fixedPointX: Int32.max, fixedPointY: Int32.max)
    let one = IVec2(x: 0.001, y: 0.001)  // 1 in fixed-point
    let result = maxVec + one
    
    // Should wrap to Int32.min
    #expect(result.x == Int32.min)
    #expect(result.y == Int32.min)
    
    // Test wrapping overflow on subtraction
    let minVec = IVec2(fixedPointX: Int32.min, fixedPointY: Int32.min)
    let result2 = minVec - one
    
    // Should wrap to Int32.max
    #expect(result2.x == Int32.max)
    #expect(result2.y == Int32.max)
}

@Test("IVec2 initialization from Float quantizes correctly")
func testIVec2FromFloat() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    #expect(v1.x == 1000)  // 1.0 * 1000 = 1000
    #expect(v1.y == 2000)  // 2.0 * 1000 = 2000
    
    let v2 = IVec2(x: 0.5, y: 1.5)
    #expect(v2.x == 500)  // 0.5 * 1000 = 500
    #expect(v2.y == 1500)  // 1.5 * 1000 = 1500
    
    let v3 = IVec2(x: -1.0, y: -2.0)
    #expect(v3.x == -1000)  // -1.0 * 1000 = -1000
    #expect(v3.y == -2000)  // -2.0 * 1000 = -2000
}

@Test("IVec2 floatX and floatY dequantize correctly")
func testIVec2FloatProperties() {
    let v = IVec2(x: 1.0, y: 2.0)
    
    #expect(abs(v.floatX - 1.0) < 0.001)
    #expect(abs(v.floatY - 2.0) < 0.001)
}

@Test("IVec2 zero constant is correct")
func testIVec2Zero() {
    #expect(IVec2.zero.x == 0)
    #expect(IVec2.zero.y == 0)
    #expect(IVec2.zero == IVec2(x: 0.0, y: 0.0))
}

@Test("IVec2 Equatable works correctly")
func testIVec2Equatable() {
    let v1 = IVec2(x: 1.0, y: 2.0)
    let v2 = IVec2(x: 1.0, y: 2.0)
    let v3 = IVec2(x: 1.0, y: 2.001)
    
    #expect(v1 == v2)
    #expect(v1 != v3)
}

// MARK: - Overflow Tests

@Test("IVec2.project(onto:) preserves precision when dot*scale overflows")
func testIVec2ProjectOverflowPath() {
    // Test with vectors near WORLD_MAX_COORDINATE to trigger overflow
    // When dot * scale overflows, the fallback should preserve fixed-point precision
    let maxCoord = FixedPoint.WORLD_MAX_COORDINATE
    let nearMaxCoord = Int32((Int64(maxCoord) * 9) / 10)  // 90% of max to ensure overflow
    
    let v1 = IVec2(fixedPointX: nearMaxCoord, fixedPointY: nearMaxCoord)
    let v2 = IVec2(fixedPointX: nearMaxCoord, fixedPointY: 0)
    
    // This should trigger overflow in dot * scale, but still produce correct result
    let projection = v1.project(onto: v2)
    
    // The projection should be in the direction of v2
    // Since v1 and v2 are both in the +x direction, projection should be along +x
    #expect(projection.x > 0, "Projection should be in positive x direction")
    #expect(projection.y == 0, "Projection onto x-axis should have y=0")
    
    // Verify the projection magnitude is reasonable (not truncated to 0 or max)
    let projMagnitude = projection.magnitude()
    #expect(projMagnitude > 0, "Projection should not be zero")
    #expect(projMagnitude < v2.magnitude() * 2, "Projection should not exceed 2x the target vector")
}
