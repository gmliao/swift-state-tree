// Tests/SwiftStateTreeTransportTests/KeyedGates.swift
//
// Gates for static resolvers, one per key for the whole process. Swift Testing runs tests in
// parallel in one process, so a key two tests both use opens one test's gate from the other.
// Keys come only from the registry's counter (`freshKey()`, or `fresh` for a key built from
// it, such as a land or client ID), never a literal. A key registered twice, or one looked up
// strictly that was never registered, records an issue. See
// `Notes/solutions/2026-11-05-hold-points-not-timing-in-race-tests.md`.

import Foundation
import Testing

final class KeyedGates<Key: Hashable, Gate: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [Key: Gate] = [:]
    private var next: Int
    private let make: () -> Gate

    /// `firstNumber` only keeps keys recognisable in logs; uniqueness comes from the counter.
    init(firstNumber: Int = 1, _ make: @escaping () -> Gate) {
        self.next = firstNumber
        self.make = make
    }

    /// A key built from a number no other test or case has (`makeKey` must keep it in the key,
    /// as is), registered with its gate.
    func fresh(_ makeKey: (Int) -> Key, sourceLocation: SourceLocation = #_sourceLocation) -> Key {
        let number = lock.withLock {
            defer { next += 1 }
            return next
        }
        let key = makeKey(number)
        _ = register(key, sourceLocation: sourceLocation)
        return key
    }

    /// Registers `key` with a new gate. A key already registered is a test bug (two tests, or a
    /// literal reused): recorded as an issue, and the existing gate is kept.
    @discardableResult
    func register(_ key: Key, sourceLocation: SourceLocation = #_sourceLocation) -> Gate {
        lock.withLock {
            if let gate = gates[key] {
                Issue.record("Gate key \(key) was registered twice: keys must be unique per test", sourceLocation: sourceLocation)
                return gate
            }
            let gate = make()
            gates[key] = gate
            return gate
        }
    }

    /// The gate of a registered key. A key never registered is a test bug (a literal or derived
    /// key two tests can share): recorded as an issue, and a gate is still returned so the test
    /// runs on to its other checks.
    func gate(_ key: Key, sourceLocation: SourceLocation = #_sourceLocation) -> Gate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            Issue.record("Gate key \(key) wasn't registered: a literal or derived key can be shared by parallel tests", sourceLocation: sourceLocation)
            let gate = make()
            gates[key] = gate
            return gate
        }
    }

    /// The gate of `key` if a test registered it, for a resolver that lets every other key
    /// through.
    func registeredGate(_ key: Key) -> Gate? {
        lock.withLock { gates[key] }
    }
}

extension KeyedGates where Key == Int {
    convenience init(firstKey: Int = 1, _ make: @escaping () -> Gate) {
        self.init(firstNumber: firstKey, make)
    }

    /// A key no other test or case has, with its gate registered. Pass it to whatever the
    /// resolver reads (a payload field, a player or land ID) as is, never with an offset.
    func freshKey(sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        fresh({ $0 }, sourceLocation: sourceLocation)
    }
}
