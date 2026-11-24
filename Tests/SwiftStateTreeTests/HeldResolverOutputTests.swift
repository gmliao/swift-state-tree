// Tests/SwiftStateTreeTests/HeldResolverOutputTests.swift
//
// A resolver output as an item holds it: produced live, or read from a record in replay. One
// projection writes both into the record; the monitor sends a step's state as JSON text.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@PlainData
struct HeldQuote: ResolverOutput, Equatable {
    let cents: Int64
    let label: String
}

private func canonicalBytes(_ value: AnyCodable) throws -> [UInt8] {
    try CanonicalMessagePack.encode(value)
}

@Suite("A held resolver output projects into the record; the monitor's state is JSON text")
struct HeldResolverOutputTests {
    @Test("The record projection writes a live output's type and value, and a recorded one's type and tree as read")
    func projectsLiveAndRecorded() throws {
        let tree = AnyCodable(["cents": AnyCodable(5), "label": AnyCodable("old")])
        let held: [String: HeldResolverOutput] = [
            "fresh": .live(HeldQuote(cents: 7, label: "new")),
            "replayed": .recorded(RecordedResolverOutput(typeIdentifier: "EarlierQuote", value: tree, integralFloats: true)),
        ]
        let entries = held.recordedEntries
        #expect(entries.count == 2)
        let fresh = try #require(entries["fresh"])
        #expect(fresh.typeIdentifier == "HeldQuote")
        #expect(try canonicalBytes(fresh.value) == canonicalBytes(AnyCodable(HeldQuote(cents: 7, label: "new"))))
        let replayed = try #require(entries["replayed"])
        #expect(replayed.typeIdentifier == "EarlierQuote")
        #expect(try canonicalBytes(replayed.value) == canonicalBytes(tree))
    }

    @Test("The monitor's state text: a String passes through, any other value is JSON text with sorted keys")
    func stateText() {
        #expect(ReevaluationStateText.text(of: AnyCodable(#"{"b":1}"#)) == #"{"b":1}"#)
        let object = AnyCodable(["b": AnyCodable(1), "a": AnyCodable("x")])
        #expect(ReevaluationStateText.text(of: object) == #"{"a":"x","b":1}"#)
    }
}
