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

    @Test("A recorded output whose bytes don't read back as a tree has no record entry (#700 K1b-1)")
    func unreadableRecordedOutputHasNoEntry() throws {
        // Nested past the canonical limit: the encode fails, and the item holds the failure.
        var deep = AnyCodable(0)
        for _ in 0...CanonicalMessagePack.maxDepth { deep = AnyCodable([deep]) }
        let tooDeep = RecordedResolverOutput(typeIdentifier: "Deep", value: deep)
        guard case .failed(.recordTooDeep) = tooDeep.payload else {
            Issue.record("the too-deep tree was held as \(tooDeep.payload)")
            return
        }
        // An unsigned value above Int.max, read with strict integral floats.
        let big = RecordedResolverOutput(typeIdentifier: "Big", value: AnyCodable(UInt64.max), integralFloats: false)
        let held: [String: HeldResolverOutput] = [
            "deep": .recorded(tooDeep),
            "big": .recorded(big),
            "fresh": .live(HeldQuote(cents: 1, label: "control")),
        ]
        let entries = held.recordedEntries
        #expect(entries["deep"] == nil)
        #expect(entries["big"] == nil)
        // Control: the live output still projects.
        #expect(entries["fresh"]?.typeIdentifier == "HeldQuote")
    }

    @Test("The monitor's state text: a String passes through, any other value is JSON text with sorted keys")
    func stateText() throws {
        #expect(try ReevaluationStateText.text(of: AnyCodable(#"{"b":1}"#)) == #"{"b":1}"#)
        // Eight keys, so an unsorted encoding can't pass by chance.
        let object = AnyCodable(["h": AnyCodable(0), "c": AnyCodable(1), "a": AnyCodable(2), "f": AnyCodable(3), "b": AnyCodable(4), "g": AnyCodable(5), "d": AnyCodable(6), "e": AnyCodable(7)])
        #expect(try ReevaluationStateText.text(of: object) == #"{"a":2,"b":4,"c":1,"d":6,"e":7,"f":3,"g":5,"h":0}"#)
        // A scalar is a JSON fragment; a value JSON can't hold throws.
        #expect(try ReevaluationStateText.text(of: AnyCodable(42)) == "42")
        #expect(throws: EncodingError.self) { try ReevaluationStateText.text(of: AnyCodable(Double.nan)) }
    }

    @Test("The projector: a scalar state projects to no keys, as before; a state JSON can't hold fails the tick")
    func projectorScalarAndUnencodable() throws {
        func result(_ state: AnyCodable) -> ReevaluationStepResult {
            ReevaluationStepResult(tickId: 1, stateHash: "h", recordedHash: "h", isMatch: true, actualState: state)
        }
        let projector = HeroDefenseReplayProjector()
        for scalar in [AnyCodable(42), AnyCodable(true)] {
            #expect(try projector.project(result(scalar)).stateObject.isEmpty)
        }
        #expect(throws: EncodingError.self) { try projector.project(result(AnyCodable(Double.nan))) }
    }
}
