// Tests/SwiftStateTreeTests/ReplayJSONAllowanceTests.swift
//
// Pins that the integral-float allowance tracks whether the source parsed JSON bytes, not whether
// its type is JSONReevaluationSource (#824). `init(metadata:frames:)` holds canonical frames built
// in memory and must be strict; only `init(data:)` and `init(filePath:)` grant the allowance.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@Suite("Replay JSON allowance is granted by whether the source read JSON bytes (#824)")
struct ReplayJSONAllowanceTests {
    static let minimalRecord = Data(
        #"{"recordMetadata":{"landID":"l","landType":"t","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":[]}"#.utf8
    )

    static func metadata() -> ReevaluationRecordMetadata {
        ReevaluationRecordMetadata(landID: "l", landType: "t", createdAt: Date(timeIntervalSince1970: 0), metadata: [:], version: "2.6")
    }

    @Test("JSONReevaluationSource(data:) sets readsJSONRecord = true")
    func dataInitSetsReadsJSONRecord() throws {
        let source = try JSONReevaluationSource(data: Self.minimalRecord)
        #expect(source.readsJSONRecord == true)
    }

    @Test("JSONReevaluationSource(metadata:frames:) sets readsJSONRecord = false")
    func metadataFramesInitDoesNotSetReadsJSONRecord() {
        let source = JSONReevaluationSource(metadata: Self.metadata(), frames: [])
        #expect(source.readsJSONRecord == false)
    }

    @Test("integralFloats(for:) is false for a source built with init(metadata:frames:)")
    func integralFloatsIsFalseForInMemorySource() {
        let source = JSONReevaluationSource(metadata: Self.metadata(), frames: [])
        #expect(ReevaluationReplayFrame.integralFloats(for: source) == false)
    }

    @Test("FaultingReevaluationSource forwards readsJSONRecord: a wrapped JSON read reports true")
    func faultingSourceForwardsTrue() throws {
        let wrapped = FaultingReevaluationSource(base: try JSONReevaluationSource(data: Self.minimalRecord), faults: ReplayRunnerFaults())
        #expect(wrapped.readsJSONRecord == true)
        #expect(ReevaluationReplayFrame.integralFloats(for: wrapped) == true)
    }

    @Test("FaultingReevaluationSource forwards readsJSONRecord: a wrapped in-memory source reports false")
    func faultingSourceForwardsFalse() {
        let wrapped = FaultingReevaluationSource(base: JSONReevaluationSource(metadata: Self.metadata(), frames: []), faults: ReplayRunnerFaults())
        #expect(wrapped.readsJSONRecord == false)
        #expect(ReevaluationReplayFrame.integralFloats(for: wrapped) == false)
    }
}
