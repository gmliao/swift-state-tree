// Tests/SwiftStateTreeTests/RegistrationDebugGuardTests.swift
//
// The registration's value walks (a class, an open type or a `Decimal` in synced state) run in
// debug builds only. The compiler refuses all three in state, so the walks guard a hand-written
// `PlainData` witness during development, and a release build doesn't pay for them. The fixtures
// are the walks' own (SyncValueSemanticsTests, SyncRegistrationTests, DecimalRegistrationTests).

import Foundation
import Testing
@testable import SwiftStateTree

/// Used by the probe test only: the registration cache is per type, so a type no other test
/// registers is walked here.
@StateNodeBuilder
struct GuardProbeRoot: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var names: [String: Int] = ["a": 1]
    init() {}
}

private func registrationError<State: StateNodeProtocol>(_ type: State.Type, _ name: String) -> LandRegistrationError? {
    do {
        try Land(name, using: type) { Rules {} }.validateForRegistration(context: .encodingIndependent)
        return nil
    } catch let error as LandRegistrationError {
        return error
    } catch {
        Issue.record("expected LandRegistrationError, got \(error)")
        return nil
    }
}

@Suite("The registration's value walks are a debug-build guard")
struct RegistrationDebugGuardTests {
    #if DEBUG
    @Test("Debug: a hand-witnessed class in a synced field is refused, server-only and self-converting ones included, and the error says what to change")
    func debugRegistrationRefusesHandWrittenClassWitness() {
        let problems = registrationError(ValueCheckClassFieldRoot.self, "guard-class")?.sync?.problems ?? []
        guard problems.count == 1, case .valueSemantics(let error) = problems[0] else {
            Issue.record("expected one value-semantics row: \(problems)")
            return
        }
        #expect(error.violations == [
            .init(path: "ValueCheckClassFieldRoot.inventory", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckClassFieldRoot.hidden", typeName: "ValueCheckObject"),
            .init(path: "ValueCheckClassFieldRoot.convertible", typeName: "ValueCheckConvertibleObject"),
        ])
        let text = "\(error)"
        #expect(text.contains("ValueCheckClassFieldRoot.inventory: ValueCheckObject is a class; synced state must be value types"))
        #expect(text.contains("land's services"))
    }

    @Test("Debug: hand-witnessed open types (Any, AnyObject, AnyHashable, AnyCodable) are refused as elements, keys, values and wrapped types")
    func debugRegistrationRefusesHandWrittenAny() {
        let problems = registrationError(RegistrationOpenRoot.self, "guard-open")?.sync?.problems
        #expect(problems == [
            .existentialField(path: "RegistrationOpenRoot.holder.bag[*]", typeName: "Any"),
            .existentialField(path: "RegistrationOpenRoot.holder.hashed[key]", typeName: "AnyHashable"),
            .existentialField(path: "RegistrationOpenRoot.holder.boxed", typeName: "AnyCodable"),
            .existentialField(path: "RegistrationOpenRoot.holder.list[*]", typeName: "AnyObject"),
        ], "\(String(describing: problems))")
    }

    @Test("Debug: a hand-witnessed Decimal is refused through optionals, arrays, sets and dictionary values; a server-only field is skipped")
    func debugRegistrationRefusesHandWrittenDecimal() {
        let problems = registrationError(DecimalSyncedRoot.self, "guard-decimal")?.sync?.problems
        #expect(problems == [
            .decimalField(path: "DecimalSyncedRoot.holder.amount"),
            .decimalField(path: "DecimalSyncedRoot.maybe.amount"),
            .decimalField(path: "DecimalSyncedRoot.list[*].amount"),
            .decimalField(path: "DecimalSyncedRoot.unique[*].amount"),
            .decimalField(path: "DecimalSyncedRoot.byName[*].amount"),
        ], "\(String(describing: problems))")
        #expect(SyncRegistration.problems(DecimalCleanRoot.self).isEmpty)
        let message = SyncRegistrationError.Problem.decimalField(path: "Root.price").description
        #expect(message.contains("Root.price") && message.contains("integer of the smallest unit"), "\(message)")
    }

    @Test("Debug: registering a new state type runs the value walks")
    func debugRegistrationRunsTheValueWalks() throws {
        let probe = RegistrationWalkProbe()
        try SyncRegistration.$walkProbe.withValue(probe) {
            try Land("guard-probe", using: GuardProbeRoot.self) { Rules {} }
                .validateForRegistration(context: .encodingIndependent)
        }
        #expect(probe.walks >= 1, "the probe moves when the walks run")
    }
    #else
    @Test("Release: registration runs no value walk, and a hand-witnessed class, open type or Decimal registers")
    func releaseRegistrationRunsNoValueWalk() throws {
        let probe = RegistrationWalkProbe()
        try SyncRegistration.$walkProbe.withValue(probe) {
            try Land("guard-probe", using: GuardProbeRoot.self) { Rules {} }
                .validateForRegistration(context: .encodingIndependent)
            #expect(registrationError(ValueCheckClassFieldRoot.self, "guard-class") == nil)
            #expect(SyncRegistration.problems(RegistrationOpenRoot.self).isEmpty)
            #expect(SyncRegistration.problems(DecimalSyncedRoot.self).isEmpty)
        }
        #expect(probe.walks == 0)
    }
    #endif

    @Test("Every build: the conversion refuses what a release registration lets in, at the land's first sync")
    func conversionRefusesWhatReleaseLetsIn() {
        #expect(throws: SyncError.self) { _ = try ValueCheckClassFieldRoot().snapshot(for: nil, dirtyFields: nil) }
        #expect(throws: SyncError.self) { _ = try DecimalSyncedRoot().snapshot(for: nil, dirtyFields: nil) }
    }
}
