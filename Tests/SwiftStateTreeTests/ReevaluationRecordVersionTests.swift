// Tests/SwiftStateTreeTests/ReevaluationRecordVersionTests.swift
//
// Record format versions are compared by major version only.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Re-evaluation record version")
struct ReevaluationRecordVersionTests {
    @Test("The producer writes 2.1")
    func currentVersion() {
        #expect(ReevaluationRecordVersion.current == "2.1")
    }

    @Test("Same major, any minor, is compatible in both directions")
    func sameMajor() {
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.1", required: "2.0"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "2.1"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "2.0"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2.7", required: "2"))
        #expect(ReevaluationRecordVersion.isCompatible(recorded: "2", required: "2.1"))
    }

    @Test("A different major, a missing or a malformed version is not")
    func incompatible() {
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "1.0", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "3.0", required: "2.1"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: nil, required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "x.1", required: "2.0"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "2.0", required: "two"))
        #expect(!ReevaluationRecordVersion.isCompatible(recorded: "20.0", required: "2.0"))
    }

    @Test("Minor versions are parsed for feature checks")
    func minor() {
        #expect(ReevaluationRecordVersion.minor(of: "2.1") == 1)
        #expect(ReevaluationRecordVersion.minor(of: "2.0") == 0)
        #expect(ReevaluationRecordVersion.minor(of: "2") == 0)
        #expect(ReevaluationRecordVersion.minor(of: nil) == nil)
        #expect(ReevaluationRecordVersion.minor(of: "2.x") == nil)
    }
}
