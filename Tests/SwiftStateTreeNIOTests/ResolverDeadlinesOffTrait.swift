// Tests/SwiftStateTreeNIOTests/ResolverDeadlinesOffTrait.swift
//
// `.resolverDeadlinesOff`: runs a test, or every test of a suite, with both resolver deadlines
// off. A test that holds a resolver behind a gate is about order, and on a loaded runner the time
// between its steps is unbounded; under the default 5 s wall-clock deadline the resolver can time
// out before the test opens the gate. A test that sets its own deadline (`withValue` inside) still
// gets it. Not for tests of the deadline itself. The same trait is in SwiftStateTreeTests and
// SwiftStateTreeTransportTests; the differential harness (#555) runs under it.

import Testing
@testable import SwiftStateTree

struct ResolverDeadlinesOffTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ResolverDeadline.$overrideForTesting.withValue(.zero) {
            try await ResolverDeadline.$initOverrideForTesting.withValue(.zero) {
                try await function()
            }
        }
    }
}

extension Trait where Self == ResolverDeadlinesOffTrait {
    /// Both resolver deadlines off (`ResolverDeadline.overrideForTesting` and
    /// `initOverrideForTesting` set to `.zero`) for a test or every test of a suite.
    static var resolverDeadlinesOff: Self { Self() }
}
