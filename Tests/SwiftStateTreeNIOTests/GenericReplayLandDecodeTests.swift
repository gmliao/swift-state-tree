// Tests for GenericReplayLand state decode (decodeReplayState).
// Verifies that replay actualState JSON is decoded correctly for flat and "values" wrapper formats.

import Foundation
import SwiftStateTree
import Testing
@testable import SwiftStateTreeReevaluationMonitor

private struct SimpleDecodable: Decodable, Equatable {
    let x: Int
    let label: String?
}

@Suite("GenericReplayLand decodeReplayState")
struct GenericReplayLandDecodeTests {

    @Test("decodeReplayState returns nil when actualState is nil")
    func decodeReturnsNilForNilInput() {
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: nil)
        #expect(result == nil)
    }

    @Test("decodeReplayState returns nil when actualState.base is not a String")
    func decodeReturnsNilWhenBaseIsNotString() {
        let anyCodable = AnyCodable(42)
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: anyCodable)
        #expect(result == nil)
    }

    @Test("decodeReplayState decodes flat JSON when actualState.base is JSON string")
    func decodeFlatJSON() {
        let json = #"{"x":10,"label":"test"}"#
        let anyCodable = AnyCodable(json)
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: anyCodable)
        #expect(result != nil)
        #expect(result?.x == 10)
        #expect(result?.label == "test")
    }

    @Test("decodeReplayState decodes values wrapper format")
    func decodeValuesWrapperFormat() {
        let json = #"{"values":{"x":20,"label":"wrapped"}}"#
        let anyCodable = AnyCodable(json)
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: anyCodable)
        #expect(result != nil)
        #expect(result?.x == 20)
        #expect(result?.label == "wrapped")
    }

    @Test("decodeReplayState returns nil for invalid JSON")
    func decodeReturnsNilForInvalidJSON() {
        let anyCodable = AnyCodable("not valid json {")
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: anyCodable)
        #expect(result == nil)
    }

    @Test("decodeReplayState returns nil when flat decode fails and values wrapper is missing")
    func decodeReturnsNilWhenBothFormatsFail() {
        let json = #"{"other":"structure"}"#
        let anyCodable = AnyCodable(json)
        let result: SimpleDecodable? = decodeReplayState(SimpleDecodable.self, from: anyCodable)
        #expect(result == nil)
    }

    /// Regression: snapshot/replay JSON uses string keys for dictionaries (e.g. players, monsters).
    /// Decoding must produce non-empty collections when the "values" wrapper contains them.
    @Test("decodeReplayState decodes values wrapper with string-keyed dictionary (e.g. players)")
    func decodeValuesWrapperWithStringKeyedDictionary() {
        // Simulates StateSnapshot format: {"values": {"players": {"uuid-1": {...}, "uuid-2": {...}}}}
        let json = #"{"values":{"players":{"p1":{"x":1,"label":"a"},"p2":{"x":2,"label":"b"}}}}"#
        struct StateWithDict: Decodable {
            let players: [String: SimpleDecodable]
        }
        let anyCodable = AnyCodable(json)
        let result: StateWithDict? = decodeReplayState(StateWithDict.self, from: anyCodable)
        #expect(result != nil)
        #expect(result?.players.count == 2)
        #expect(result?.players["p1"]?.x == 1)
        #expect(result?.players["p2"]?.label == "b")
    }
}
