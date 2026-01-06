// Tests/SwiftStateTreeDeterministicMathTests/IVec3Tests.swift
//
// Tests for IVec3 integer vector operations.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("IVec3 addition is deterministic")
func testIVec3Addition() {
    let v1 = IVec3(x: 1.0, y: 2.0, z: 3.0)
    let v2 = IVec3(x: 0.5, y: 0.3, z: 0.1)
    let sum = v1 + v2
    
    #expect(sum.x == 1500)  // 1.0 + 0.5 = 1.5 -> 1500
    #expect(sum.y == 2300)  // 2.0 + 0.3 = 2.3 -> 2300
    #expect(sum.z == 3100)  // 3.0 + 0.1 = 3.1 -> 3100
}

@Test("IVec3 subtraction is deterministic")
func testIVec3Subtraction() {
    let v1 = IVec3(x: 1.0, y: 2.0, z: 3.0)
    let v2 = IVec3(x: 0.5, y: 0.3, z: 0.1)
    let diff = v1 - v2
    
    #expect(diff.x == 500)  // 1.0 - 0.5 = 0.5 -> 500
    #expect(diff.y == 1700)  // 2.0 - 0.3 = 1.7 -> 1700
    #expect(diff.z == 2900)  // 3.0 - 0.1 = 2.9 -> 2900
}

@Test("IVec3 Codable serialization preserves values")
func testIVec3Codable() throws {
    let original = IVec3(x: 1.0, y: 2.0, z: 3.0)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(IVec3.self, from: data)
    
    #expect(decoded == original)
}
