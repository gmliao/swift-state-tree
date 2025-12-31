// Tests/SwiftStateTreeTransportTests/TransportCodecTests.swift
//
// Tests for TransportCodec protocol and implementations

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test Codable Types

struct TestCodableStruct: Codable, Equatable {
    let id: Int
    let name: String
    let values: [String: Int]
}

// MARK: - TransportCodec Tests

@Suite("TransportCodec Tests")
struct TransportCodecTests {
    
    @Test("JSONTransportCodec encodes and decodes simple struct")
    func testJSONCodecEncodeDecode() throws {
        let codec = JSONTransportCodec()
        let original = TestCodableStruct(
            id: 123,
            name: "test",
            values: ["a": 1, "b": 2]
        )
        
        let encoded = try codec.encode(original)
        let decoded = try codec.decode(TestCodableStruct.self, from: encoded)
        
        #expect(decoded == original)
        #expect(codec.encoding == .json)
    }
    
    @Test("JSONTransportCodec encodes StateUpdate")
    func testJSONCodecEncodeStateUpdate() throws {
        let codec = JSONTransportCodec()
        let patches: [StatePatch] = [
            StatePatch(path: "/test", operation: .set(.int(42)))
        ]
        let update = StateUpdate.diff(patches)
        
        let encoded = try codec.encode(update)
        let decoded = try codec.decode(StateUpdate.self, from: encoded)
        
        if case .diff(let decodedPatches) = decoded {
            #expect(decodedPatches.count == 1)
            #expect(decodedPatches[0].path == "/test")
        } else {
            Issue.record("Expected .diff case")
        }
    }
    
    @Test("JSONTransportCodec encodes StateSnapshot")
    func testJSONCodecEncodeStateSnapshot() throws {
        let codec = JSONTransportCodec()
        let snapshot = StateSnapshot(values: [
            "round": .int(1),
            "players": .object([
                "player-1": .object([
                    "hp": .int(100)
                ])
            ])
        ])
        
        let encoded = try codec.encode(snapshot)
        let decoded = try codec.decode(StateSnapshot.self, from: encoded)
        
        #expect(decoded.values.count == 2)
        #expect(decoded.values["round"] == .int(1))
    }
    
    @Test("JSONTransportCodec handles encoding errors")
    func testJSONCodecEncodingError() {
        let codec = JSONTransportCodec()
        
        // Create a type that will fail encoding
        struct NonEncodable: Encodable {
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "TestError", code: 1)
            }
        }
        
        let value = NonEncodable()
        #expect(throws: Error.self) {
            try codec.encode(value)
        }
    }
    
    @Test("JSONTransportCodec handles decoding errors")
    func testJSONCodecDecodingError() {
        let codec = JSONTransportCodec()
        let invalidData = Data("invalid json".utf8)
        
        #expect(throws: Error.self) {
            try codec.decode(TestCodableStruct.self, from: invalidData)
        }
    }
    
    @Test("TransportEncoding makes correct codec")
    func testTransportEncodingMakeCodec() {
        let jsonCodec = TransportEncoding.json.makeCodec()
        #expect(jsonCodec is JSONTransportCodec)
        #expect(jsonCodec.encoding == .json)
    }
}
