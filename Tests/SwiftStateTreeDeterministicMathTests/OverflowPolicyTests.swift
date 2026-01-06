// Tests/SwiftStateTreeDeterministicMathTests/OverflowPolicyTests.swift
//
// Tests for OverflowPolicy and OverflowHandler.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("OverflowHandler wrapping policy wraps on overflow")
func testOverflowHandlerWrapping() {
    let maxValue = Int32.max
    let result = OverflowHandler.add(maxValue, 1, policy: .wrapping)
    #expect(result == Int32.min)
    
    let minValue = Int32.min
    let result2 = OverflowHandler.subtract(minValue, 1, policy: .wrapping)
    #expect(result2 == Int32.max)
}

@Test("OverflowHandler clamping policy clamps on overflow")
func testOverflowHandlerClamping() {
    let maxValue = Int32.max
    let result = OverflowHandler.add(maxValue, 1, policy: .clamping)
    #expect(result == Int32.max)
    
    let minValue = Int32.min
    let result2 = OverflowHandler.subtract(minValue, 1, policy: .clamping)
    #expect(result2 == Int32.min)
}

@Test("OverflowHandler multiply works correctly")
func testOverflowHandlerMultiply() {
    let value: Int32 = 1000
    let scalar: Int32 = 2
    
    let wrappingResult = OverflowHandler.multiply(value, by: scalar, policy: .wrapping)
    #expect(wrappingResult == 2000)
    
    let clampingResult = OverflowHandler.multiply(value, by: scalar, policy: .clamping)
    #expect(clampingResult == 2000)
}
