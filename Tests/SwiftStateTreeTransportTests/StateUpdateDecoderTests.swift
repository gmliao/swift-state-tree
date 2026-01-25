// Tests/SwiftStateTreeTransportTests/StateUpdateDecoderTests.swift
//
// Tests for state update decoders - specifically NSNull handling in PathHash mode.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - OpcodeJSONStateUpdateDecoder NSNull Handling Tests

@Test("OpcodeJSONStateUpdateDecoder handles NSNull in dynamic keys (PathHash mode)")
func testOpcodeJSONDecoderHandlesNSNull() throws {
    // This test verifies the fix for PathHash mode where encoder emits null
    // for patches with no dynamic keys (static paths)
    
    let pathPattern = "count"
    let pathHash: UInt32 = 100
    let pathHasher = PathHasher(pathHashes: [pathPattern: pathHash])
    
    let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: pathHasher)
    
    // Opcode: 1 = diff
    // Patch format: [pathHash, dynamicKeys, patchOpcode, value]
    // patchOpcode: 1 = set
    let jsonData = """
    [1, [100, null, 1, 42]]
    """.data(using: .utf8)!
    
    // This should not throw - NSNull should be treated as empty list
    let decodedUpdate = try decoder.decode(data: jsonData)
    
    // Verify the result
    switch decodedUpdate.update {
    case .diff(let patches):
        #expect(patches.count == 1)
        #expect(patches[0].path == "/count")
    case .firstSync(let patches):
        #expect(patches.count == 1)
        #expect(patches[0].path == "/count")
    case .noChange:
        Issue.record("Unexpected noChange result")
    }
}

@Test("OpcodeJSONStateUpdateDecoder handles empty array in dynamic keys (PathHash mode)")
func testOpcodeJSONDecoderHandlesEmptyArray() throws {
    let pathPattern = "ticks"
    let pathHash: UInt32 = 200
    let pathHasher = PathHasher(pathHashes: [pathPattern: pathHash])
    
    let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: pathHasher)
    
    // Test with empty array - should behave same as null
    let jsonData = """
    [1, [200, [], 1, 5]]
    """.data(using: .utf8)!
    
    let decodedUpdate = try decoder.decode(data: jsonData)
    
    switch decodedUpdate.update {
    case .diff(let patches), .firstSync(let patches):
        #expect(patches.count == 1)
        #expect(patches[0].path == "/ticks")
    case .noChange:
        Issue.record("Unexpected noChange result")
    }
}

@Test("OpcodeJSONStateUpdateDecoder handles wildcard path with string key (PathHash mode)")
func testOpcodeJSONDecoderHandlesWildcardWithStringKey() throws {
    let basePattern = "players.*"
    let pathHash: UInt32 = 300
    let pathHasher = PathHasher(pathHashes: [basePattern: pathHash])
    
    let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: pathHasher)
    
    // Test with single string key (wildcard substitution)
    let jsonData = """
    [1, [300, "player-1", 1, {"name": "Alice"}]]
    """.data(using: .utf8)!
    
    let decodedUpdate = try decoder.decode(data: jsonData)
    
    switch decodedUpdate.update {
    case .diff(let patches), .firstSync(let patches):
        #expect(patches.count == 1)
        #expect(patches[0].path == "/players/player-1")
    case .noChange:
        Issue.record("Unexpected noChange result")
    }
}

@Test("OpcodeJSONStateUpdateDecoder without PathHasher uses legacy format")
func testOpcodeJSONDecoderLegacyFormat() throws {
    // Without PathHasher, decoder should use legacy string path format
    let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: nil)
    
    // Legacy format: [path, opcode, value]
    let jsonData = """
    [1, ["/count", 1, 42]]
    """.data(using: .utf8)!
    
    let decodedUpdate = try decoder.decode(data: jsonData)
    
    switch decodedUpdate.update {
    case .diff(let patches), .firstSync(let patches):
        #expect(patches.count == 1)
        #expect(patches[0].path == "/count")
        if case .set(let value) = patches[0].operation {
            #expect(value == .int(42))
        }
    case .noChange:
        Issue.record("Unexpected noChange result")
    }
}
