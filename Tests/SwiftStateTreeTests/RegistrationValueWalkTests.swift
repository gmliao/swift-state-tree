// Tests/SwiftStateTreeTests/RegistrationValueWalkTests.swift
//
// The registration's value walks refuse a class, an open type or a `Decimal` in synced state, in
// every build. The compiler refuses all three in state, so only a hand-written `PlainData` witness
// brings one in; registration then refuses the land before it runs, and the conversion stays as
// the backstop for what registration can't see. The fixtures are the walks' own
// (SyncValueSemanticsTests, SyncRegistrationTests, DecimalRegistrationTests). CI also runs this
// suite in release (`build-and-test.yml`).

import Foundation
import Testing
@testable import SwiftStateTree

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

@Suite("The registration's value walks refuse what a hand-written witness lets into state")
struct RegistrationValueWalkTests {
    @Test("A hand-witnessed class in a synced field is refused, server-only and self-converting ones included, and the error says what to change")
    func registrationRefusesHandWrittenClassWitness() {
        let problems = registrationError(ValueCheckClassFieldRoot.self, "walk-class")?.sync?.problems ?? []
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

    @Test("Hand-witnessed open types (Any, AnyObject, AnyHashable, AnyCodable) are refused as elements, keys, values and wrapped types")
    func registrationRefusesHandWrittenAny() {
        let problems = registrationError(RegistrationOpenRoot.self, "walk-open")?.sync?.problems
        #expect(problems == [
            .existentialField(path: "RegistrationOpenRoot.holder.bag[*]", typeName: "Any"),
            .existentialField(path: "RegistrationOpenRoot.holder.hashed[key]", typeName: "AnyHashable"),
            .existentialField(path: "RegistrationOpenRoot.holder.boxed", typeName: "AnyCodable"),
            .existentialField(path: "RegistrationOpenRoot.holder.list[*]", typeName: "AnyObject"),
        ], "\(String(describing: problems))")
    }

    @Test("A hand-witnessed Decimal is refused through optionals, arrays, sets and dictionary values; a server-only field is skipped")
    func registrationRefusesHandWrittenDecimal() {
        let problems = registrationError(DecimalSyncedRoot.self, "walk-decimal")?.sync?.problems
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

    @Test("The conversion refuses the same states at their first snapshot: the backstop for what registration can't see")
    func conversionRefusesWhatRegistrationRefuses() {
        #expect(throws: SyncError.self) { _ = try ValueCheckClassFieldRoot().snapshot(for: nil, dirtyFields: nil) }
        #expect(throws: SyncError.self) { _ = try DecimalSyncedRoot().snapshot(for: nil, dirtyFields: nil) }
    }
}
