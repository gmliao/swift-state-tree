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

// MARK: - Numbers and booleans (#171)

/// The value of the single set patch in `data`.
private func decodedSetValue(_ data: Data) throws -> SnapshotValue? {
    let decoded = try OpcodeJSONStateUpdateDecoder().decode(data: data)
    guard case .diff(let patches) = decoded.update, patches.count == 1,
          case .set(let value) = patches[0].operation else { return nil }
    return value
}

@Test("OpcodeJSONStateUpdateDecoder keeps 0 and 1 as integers and true/false as booleans through an encode round trip (#171)")
func testOpcodeJSONDecoderRoundTripsZeroOneAndBooleans() throws {
    let values: [SnapshotValue] = [
        .int(0), .int(1), .int(2), .int(-1),
        .bool(false), .bool(true),
        .double(1.5), .double(0.5),
        .array([.int(0), .int(1), .bool(true)]),
        .object(["zero": .int(0), "one": .int(1), "flag": .bool(false)])
    ]
    let encoder = OpcodeJSONStateUpdateEncoder()
    for value in values {
        let update = StateUpdate.diff([StatePatch(path: "/v", operation: .set(value))])
        let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("p1"))
        #expect(try decodedSetValue(data) == value, "round trip of \(value)")
    }
}

@Test("OpcodeJSONStateUpdateDecoder reads JSON 0, 1, 1.0 as numbers and only true/false as booleans (#171)")
func testOpcodeJSONDecoderRawNumbersAndBooleans() throws {
    func frame(_ json: String) -> Data { Data("[2, [\"/v\", 1, \(json)]]".utf8) }
    #expect(try decodedSetValue(frame("0")) == .int(0))
    #expect(try decodedSetValue(frame("1")) == .int(1))
    #expect(try decodedSetValue(frame("1.5")) == .double(1.5))
    #expect(try decodedSetValue(frame("true")) == .bool(true))
    #expect(try decodedSetValue(frame("false")) == .bool(false))
    // A JSON 1.0 is a number, never a boolean; JSON does not keep 1.0 apart from 1
    let one = try decodedSetValue(frame("1.0"))
    #expect(one == .int(1) || one == .double(1.0))
}

@Test("JSONSerializationNumber classifies JSONSerialization output by its JSON text, and ignores native Swift values (#171)")
func testJSONSerializationNumberClassification() throws {
    func parsed(_ json: String) throws -> Any {
        let array = try JSONSerialization.jsonObject(with: Data("[\(json)]".utf8)) as! [Any]
        return array[0]
    }
    #expect(JSONSerializationNumber(try parsed("0")) == .int(0))
    #expect(JSONSerializationNumber(try parsed("1")) == .int(1))
    #expect(JSONSerializationNumber(try parsed("-1")) == .int(-1))
    #expect(JSONSerializationNumber(try parsed("true")) == .bool(true))
    #expect(JSONSerializationNumber(try parsed("false")) == .bool(false))
    #expect(JSONSerializationNumber(try parsed("1.5")) == .double(1.5))
    #expect(JSONSerializationNumber(try parsed("\(Int.max)")) == .int(Int.max))
    #expect(JSONSerializationNumber(try parsed("\(UInt64.max)")) == .unsigned(UInt64.max))
    // Native values are not JSONSerialization output; callers handle them with plain casts
    #expect(JSONSerializationNumber(true) == nil)
    #expect(JSONSerializationNumber(1 as Int) == nil)
    #expect(JSONSerializationNumber(1.5 as Double) == nil)
    #expect(JSONSerializationNumber("1") == nil)
}

@Test("OpcodeJSONStateUpdateDecoder keeps an unsigned integer above Int.max without wrapping (#171)")
func testOpcodeJSONDecoderUnsignedAboveIntMax() throws {
    let value = try decodedSetValue(Data("[2, [\"/v\", 1, \(UInt64.max)]]".utf8))
    // The same form the server's encoder gives a UInt64 above Int.max (#185)
    #expect(value == .string("\(UInt64.max)"))
}
