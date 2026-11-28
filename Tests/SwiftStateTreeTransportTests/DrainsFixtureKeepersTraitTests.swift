// Tests/SwiftStateTreeTransportTests/DrainsFixtureKeepersTraitTests.swift
//
// The `.drainsFixtureKeepers` trait itself: it drains the keepers a test registered when the test
// returns and when it throws (a `try #require`, a thrown error, a cancellation), and rethrows the
// test's error after the drain (#910).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct DrainsTraitState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

private struct ThrownByTheTest: Error {}

/// A keeper without a recorder: no spool file, so the trait's spool check doesn't see the keeper
/// this test still holds.
private func makeKeeper() -> LandKeeper<DrainsTraitState> {
    LandKeeper<DrainsTraitState>(
        definition: Land("drains-trait", using: DrainsTraitState.self) { Rules {} },
        initialState: DrainsTraitState(),
        autoStartLoops: false
    )
}

/// Runs `body` in the trait's scope, as a test with the trait would run.
private func inTraitScope(_ body: @escaping @Sendable () async throws -> Void) async throws {
    try await DrainsFixtureKeepersTrait().provideScope(
        for: try #require(Test.current),
        testCase: Test.Case.current,
        performing: body
    )
}

@Suite("The drainsFixtureKeepers trait (#910)")
struct DrainsFixtureKeepersTraitTests {
    @Test("A test that returns has its registered keeper drained")
    func drainsOnReturn() async throws {
        let keeper = makeKeeper()
        try await inTraitScope {
            FixtureKeepers.register(keeper)
        }
        #expect(keeper.isDraining, "the trait shut the keeper down")
    }

    @Test("A test that throws has its registered keeper drained, and its error is rethrown")
    func drainsOnThrow() async throws {
        let keeper = makeKeeper()
        await #expect(throws: ThrownByTheTest.self, "the test's own error comes out of the scope") {
            try await inTraitScope {
                FixtureKeepers.register(keeper)
                throw ThrownByTheTest()
            }
        }
        #expect(keeper.isDraining, "the trait shut the keeper down on the thrown path")
    }
}
