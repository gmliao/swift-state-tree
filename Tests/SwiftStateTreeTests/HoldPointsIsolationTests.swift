// Tests/SwiftStateTreeTests/HoldPointsIsolationTests.swift
//
// With nothing installed, `await holds.at(...)` must not suspend: an actor's code before and
// after it stays one synchronous segment, so no other job of that actor runs in between. These
// tests guard against a future change that adds a suspension to `at` (or drops its caller
// isolation): on Swift 6.4.2 (the one measured), a nonisolated async `at` that returns at once
// showed no interleaving either, so they don't reproduce a past failure.

import Foundation
import Testing
@testable import SwiftStateTree

private enum ProbePoint: Hashable, Sendable { case point }

/// An actor whose loops cross a suspension point while another task keeps calling into it.
private actor InterleavingProbe {
    var holds = HoldPoints<ProbePoint>()
    private(set) var calls = 0

    /// Parked by `acrossRealSuspension`; only a `call` from another task resumes it.
    private var parked: CheckedContinuation<Void, Never>?

    func call() {
        calls += 1
        parked?.resume()
        parked = nil
    }

    /// Calls of other jobs that ran between the start and the end of 2000 empty hold points.
    func acrossEmptyHoldPoints() async -> Int {
        let start = calls
        for _ in 0..<2000 { await holds.at(.point) }
        return calls - start
    }

    /// The control: a real suspension that only another task's `call` ends, so at least one
    /// call runs inside it, whatever the scheduling (a yield may let none in under load, #193).
    func acrossRealSuspension() async -> Int {
        let start = calls
        await withCheckedContinuation { parked = $0 }
        return calls - start
    }
}

@StateNodeBuilder
struct HoldIsolationState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0

    public init() {}
}

@Suite("HoldPoints: no executor hop when nothing is installed")
struct HoldPointsIsolationTests {
    @Test("no other job of the actor runs across an empty hold point (a real suspension, the control, lets them in)")
    func emptyHoldPointDoesNotInterleave() async {
        let probe = InterleavingProbe()
        // Keeps calling until cancelled: it also ends the control's suspension.
        let caller = Task { while !Task.isCancelled { await probe.call() } }
        defer { caller.cancel() }
        let control = await probe.acrossRealSuspension()
        let acrossHolds = await probe.acrossEmptyHoldPoints()
        #expect(control > 0, "the probe must see interleaving across a real suspension")
        #expect(acrossHolds == 0)
    }

    @Test("maxPlayers 1: two concurrent joins with no holds installed admit exactly one")
    func concurrentJoinsRespectMaxPlayers() async throws {
        // The keeper's `.join` point sits between the maxPlayers check and the insert; a hop
        // there let the second join pass the check before the first inserted.
        for round in 0..<50 {
            let keeper = LandKeeper<HoldIsolationState>(
                definition: Land("hold-isolation-test", using: HoldIsolationState.self) {
                    AccessControl { MaxPlayers(1) }
                    Rules {}
                },
                initialState: HoldIsolationState(),
                autoStartLoops: false
            )
            async let first: Bool = Self.join(keeper, "a\(round)")
            async let second: Bool = Self.join(keeper, "b\(round)")
            let admitted = [try await first, try await second].filter { $0 }.count
            #expect(admitted == 1, "round \(round)")
            #expect(await keeper.playerCount() == 1, "round \(round)")
            await keeper.forceShutdown()
        }
    }

    /// The join with CanJoin and the maxPlayers check (`join(session:...)`).
    private static func join(_ keeper: LandKeeper<HoldIsolationState>, _ id: String) async throws -> Bool {
        do {
            let decision = try await keeper.join(
                session: PlayerSession(playerID: id),
                clientID: ClientID(id),
                sessionID: SessionID(id),
                services: LandServices()
            )
            guard case .allow = decision else { return false }
            return true
        } catch JoinError.roomIsFull {
            return false
        }
    }
}
