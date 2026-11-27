// Tests/SwiftStateTreeTransportTests/DrainsFixtureKeepersTrait.swift
//
// `.drainsFixtureKeepers`: after a test, or each test of a suite, shuts down every keeper that a
// fixture registered during it (`FixtureKeepers.register`), and fails the test if one of their
// spool files is still there (#910). A keeper with an attached adapter is a cycle until its drain
// (#346), so a fixture that never drains keeps its keeper, its recorder and its spool file until
// the process exits; a full test run left one file per such fixture in the temporary directory.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

/// The keepers fixtures created in the current test, to shut down when it ends.
final class FixtureKeepers: @unchecked Sendable {
    @TaskLocal static var current: FixtureKeepers?

    private let lock = NSLock()
    /// Each shuts its keeper down and returns the keeper's spool path, read before.
    private var drains: [@Sendable () async -> String?] = []

    /// Registers `keeper` with the current test's scope; outside one, does nothing.
    static func register<State: StateNodeProtocol>(_ keeper: LandKeeper<State>) {
        current?.append {
            let spool = await keeper.getReevaluationRecorder()?.getSpoolPath()
            await keeper.forceShutdown()
            return spool
        }
    }

    private func append(_ drain: @escaping @Sendable () async -> String?) {
        lock.withLock { drains.append(drain) }
    }

    fileprivate func take() -> [@Sendable () async -> String?] {
        lock.withLock {
            defer { drains = [] }
            return drains
        }
    }
}

struct DrainsFixtureKeepersTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let keepers = FixtureKeepers()
        defer { _ = keepers.take() }
        try await FixtureKeepers.$current.withValue(keepers) {
            try await function()
        }
        let spools = await Self.shutDown(keepers.take())
        // The drains held the keepers; they are gone now, so each recorder's deinit deletes its
        // spool file on its writer's queue.
        for spool in spools where !(await Self.removed(spool)) {
            Issue.record("a fixture's spool file is left after its keeper's drain (#910): \(spool)")
        }
    }

    /// Runs each drain, bounded by the hang bound: a test that ends with a hold still closed
    /// fails here instead of hanging.
    private static func shutDown(_ drains: [@Sendable () async -> String?]) async -> [String] {
        var spools: [String] = []
        for drain in drains {
            let ended = EventLog()
            let spool = SpoolBox()
            Task {
                spool.path = await drain()
                ended.append("ended")
            }
            guard await ended.waitFor({ !$0.isEmpty }) else {
                Issue.record("a fixture keeper's forceShutdown didn't return (#910)")
                continue
            }
            if let path = spool.path { spools.append(path) }
        }
        return spools
    }

    /// Whether `spool` is gone within the hang bound.
    private static func removed(_ spool: String) async -> Bool {
        let deadline = ContinuousClock.now + testHangBound
        while FileManager.default.fileExists(atPath: spool) {
            guard ContinuousClock.now < deadline else { return false } // wall-clock: the hang bound of this poll, never reached by a passing run
            try? await Task.sleep(for: .milliseconds(10)) // wall-clock: the file removal on the writer's queue has no event the test can await; a passing run leaves at once
        }
        return true
    }
}

private final class SpoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var path: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension Trait where Self == DrainsFixtureKeepersTrait {
    /// Shuts down the keepers fixtures registered, after a test or each test of a suite, and
    /// fails the test if one of their spool files is left (#910).
    static var drainsFixtureKeepers: Self { Self() }
}
