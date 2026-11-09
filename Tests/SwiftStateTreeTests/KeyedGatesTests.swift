// Tests/SwiftStateTreeTests/KeyedGatesTests.swift

import Foundation
import Testing

private final class CountedGate {}

@Suite("Keyed gates: keys are unique, and a duplicate or unregistered key is an issue")
struct KeyedGatesTests {
    @Test("freshKey hands out distinct keys, each with its own gate, under concurrent callers")
    func freshKeysAreDistinct() async {
        let gates = KeyedGates(firstKey: 1) { CountedGate() }
        let keys = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<200 { group.addTask { gates.freshKey() } }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(Set(keys).count == 200)
        #expect(Set(keys.map { ObjectIdentifier(gates.gate($0)) }).count == 200)
    }

    @Test("A key freshKey didn't hand out records an issue")
    func unknownKeyIsAnIssue() {
        let gates = KeyedGates(firstKey: 1) { CountedGate() }
        _ = gates.freshKey()
        withKnownIssue("a literal key") {
            _ = gates.gate(9_999)
        }
    }

    @Test("A key registered twice records an issue; a built key is registered once")
    func duplicateRegistrationIsAnIssue() {
        let gates = KeyedGates<String, CountedGate> { CountedGate() }
        let id = gates.fresh { "room-\($0)" }
        #expect(gates.registeredGate(id) != nil)
        #expect(gates.registeredGate("room-unregistered") == nil, "a lenient lookup lets other keys through")
        withKnownIssue("the same key from two tests") {
            gates.register(id)
        }
    }
}
