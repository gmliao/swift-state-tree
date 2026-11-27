// Tests/SwiftStateTreeTests/RejoinHoldsPlaceTests.swift
//
// #852: a duplicate login kicks its player's old session across an await, and the player's
// entry is gone while the kick runs. The returning player keeps its place: a newcomer that joins
// during the kick is refused with `roomIsFull`, and the land never holds more than `maxPlayers`.
// The kick is held by an OnLeave resolver that waits on a `TestGate`, never by timing.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

@StateNodeBuilder
struct RejoinState: StateNodeProtocol {
    /// "join:<player>:<client>" in the order the OnJoin handlers ran.
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@PlainData
struct RejoinResolverOutput: ResolverOutput {
    let value: Int
}

/// What an OnLeave resolver of one land does: waits on `gate` when `holdsKick`, and fails once
/// it is released when `failsAfterGate`. Keyed by the land's ID, so each test has its own.
private final class RejoinBox: @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var holds = true
    private var fails = false

    var holdsKick: Bool { get { lock.withLock { holds } } set { lock.withLock { holds = newValue } } }
    var failsAfterGate: Bool { get { lock.withLock { fails } } set { lock.withLock { fails = newValue } } }
}

private enum RejoinBoxes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var boxes: [String: RejoinBox] = [:]

    static func box(for landID: String) -> RejoinBox {
        lock.withLock {
            if let box = boxes[landID] { return box }
            let box = RejoinBox()
            boxes[landID] = box
            return box
        }
    }
}

private struct RejoinResolverFailure: Error {}

struct RejoinLeaveResolver: ContextResolver {
    typealias Output = RejoinResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> RejoinResolverOutput {
        let box = RejoinBoxes.box(for: ctx.landID)
        if box.holdsKick {
            await box.gate.arrive()
            if box.failsAfterGate { throw RejoinResolverFailure() }
        }
        return RejoinResolverOutput(value: 0)
    }
}

/// A tick land with `maxPlayers = 2`. OnJoin has no resolvers, so a join returns once it is
/// inserted, without waiting for a tick.
private func makeRejoinDefinition(withLeaveResolver: Bool = true) -> LandDefinition<RejoinState> {
    Land("rejoin-hold-test", using: RejoinState.self) {
        AccessControl { MaxPlayers(2) }
        Rules {
            OnJoin { state, ctx in
                state.log.append("join:\(ctx.playerID.rawValue):\(ctx.clientID.rawValue)")
            }
            if withLeaveResolver {
                OnLeave(resolvers: RejoinLeaveResolver.self) { _, _, _ in }
            } else {
                OnLeave { _, _ in }
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

private enum Outcome: Equatable {
    case admitted
    case roomIsFull
}

private func join(_ keeper: LandKeeper<RejoinState>, _ player: String, client: String) async throws -> Outcome {
    do {
        let decision = try await keeper.join(
            session: PlayerSession(playerID: player),
            clientID: ClientID(client),
            sessionID: SessionID(client),
            services: LandServices()
        )
        guard case .allow = decision else { return .roomIsFull }
        return .admitted
    } catch JoinError.roomIsFull {
        return .roomIsFull
    }
}

/// A keeper holding p1 and p2, a tick stepped, and the box of its land.
private func makeFullKeeper(withLeaveResolver: Bool = true) async throws -> (LandKeeper<RejoinState>, RejoinBox) {
    let landID = "rejoin-hold:\(UUID().uuidString)"
    let keeper = LandKeeper<RejoinState>(
        definition: makeRejoinDefinition(withLeaveResolver: withLeaveResolver),
        initialState: RejoinState(),
        autoStartLoops: false,
        landID: landID
    )
    #expect(try await join(keeper, "p1", client: "p1-a") == .admitted)
    #expect(try await join(keeper, "p2", client: "p2-a") == .admitted)
    await keeper.stepTickOnce()
    return (keeper, RejoinBoxes.box(for: landID))
}

@Suite("A duplicate login holds its player's place across the kick (#852)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct RejoinHoldsPlaceTests {
    @Test("a newcomer during the kick is refused, the returning player keeps its place, and the land never holds more than maxPlayers")
    func newcomerDuringKickIsRefused() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        let rejoin = Task { try await join(keeper, "p1", client: "p1-b") }
        #expect(await box.gate.waitForArrivals(1), "the kick is held in OnLeave's resolver")
        // The old entry is gone and the rejoin hasn't inserted yet.
        #expect(await keeper.playerCount() == 1)
        let newcomer = try await join(keeper, "p3", client: "p3-a")
        box.gate.open()
        let returning = try await rejoin.value
        await keeper.stepTickOnce()
        let finalCount = await keeper.playerCount()
        #expect(finalCount <= 2, "the land holds more than maxPlayers: players.count == \(finalCount)")
        #expect(newcomer == .roomIsFull, "the place wasn't free: its owner was moving it to a new connection")
        #expect(returning == .admitted)
        #expect(finalCount == 2)
        #expect(await keeper.currentState().log == ["join:p1:p1-a", "join:p2:p2-a", "join:p1:p1-b"])
    }

    /// The kick is a segment boundary: the insert runs after the kick returns, never during it.
    /// `join(playerID:)` forwards to `join(session:)` (#903), so it takes the same path.
    @Test("a join(playerID:) inserts only after its kick of the old session returns")
    func legacyJoinInsertsAfterItsKick() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        let rejoin = Task {
            try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("p1-b"), sessionID: SessionID("p1-b"))
        }
        #expect(await box.gate.waitForArrivals(1), "the kick is held in OnLeave's resolver")
        // The old entry is gone, and the join hasn't inserted yet.
        #expect(await keeper.playerCount() == 1)
        box.gate.open()
        try await rejoin.value
        #expect(await keeper.playerCount() == 2)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["join:p1:p1-a", "join:p2:p2-a", "join:p1:p1-b"])
    }

    @Test("control: without an OnLeave resolver the kick doesn't suspend, the newcomer is refused and the count stays 2")
    func noResolverNoSuspension() async throws {
        let (keeper, _) = try await makeFullKeeper(withLeaveResolver: false)
        #expect(try await join(keeper, "p1", client: "p1-b") == .admitted)
        #expect(try await join(keeper, "p3", client: "p3-a") == .roomIsFull)
        #expect(await keeper.playerCount() == 2)
    }

    @Test("control: a rejoin whose kick fails releases the hold, so a later newcomer is admitted")
    func failedKickReleasesTheHold() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        box.failsAfterGate = true
        let rejoin = Task { () -> Bool in
            do { _ = try await join(keeper, "p1", client: "p1-b"); return false } catch { return true }
        }
        #expect(await box.gate.waitForArrivals(1))
        // Held while the kick runs.
        #expect(try await join(keeper, "p3", client: "p3-a") == .roomIsFull)
        box.gate.open()
        #expect(await rejoin.value, "the kick's failure reaches the rejoin")
        // The rejoin ended without inserting: p1's place is free again, and nobody holds it.
        #expect(await keeper.playerCount() == 1)
        #expect(try await join(keeper, "p3", client: "p3-a") == .admitted)
        #expect(await keeper.playerCount() == 2)
    }

    @Test("control: a second duplicate login of the same player keeps its own hold when the first one's join ends")
    func secondLoginKeepsItsHold() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        box.failsAfterGate = true
        // The first duplicate login suspends in the kick (hold 1).
        let first = Task { () -> Bool in
            do { _ = try await join(keeper, "p1", client: "p1-b"); return false } catch { return true }
        }
        #expect(await box.gate.waitForArrivals(1))
        // The second one is held at the join hold point, after the cap check issued its hold 2.
        let atJoin = TestGate()
        defer { atJoin.open() }
        // Only the next join to reach the point is held; a later one passes.
        let claimed = NSLock()
        nonisolated(unsafe) var taken = false
        await keeper.installHolds { point in
            guard point == .join else { return }
            let mine = claimed.withLock { () -> Bool in defer { taken = true }; return !taken }
            if mine { await atJoin.arrive() }
        }
        let second = Task { try await join(keeper, "p1", client: "p1-c") }
        #expect(await atJoin.waitForArrivals(1))
        // The first one's join fails and ends now: its hold 1 is no longer the current one.
        box.gate.open()
        #expect(await first.value)
        // p1 holds no entry, and the second login's hold still keeps the place.
        #expect(await keeper.playerCount() == 1)
        #expect(try await join(keeper, "p3", client: "p3-a") == .roomIsFull, "the first join's end cleared the second's hold")
        atJoin.open()
        #expect(try await second.value == .admitted)
        #expect(await keeper.playerCount() == 2)
    }

    @Test("a newer login that inserts and leaves while the older one is still in its kick doesn't free the older one's place")
    func newerLoginEndsFirst() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        // Login A kicks the old session and parks in OnLeave's resolver (arrival 1).
        let older = Task { try await join(keeper, "p1", client: "p1-b") }
        #expect(await box.gate.waitForArrivals(1))
        // Login B finds no entry to kick, inserts, and leaves again; its OnLeave parks too (arrival 2).
        #expect(try await join(keeper, "p1", client: "p1-c") == .admitted)
        let newerLeaves = Task { try await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("p1-c"), sessionID: SessionID("p1-c")) }
        #expect(await box.gate.waitForArrivals(2))
        // A is still pending and holds p1's place: p2 plus that place fill the land.
        let newcomer = try await join(keeper, "p3", client: "p3-a")
        box.gate.open()
        // B arrived after A, so A is fenced out when its kick returns, although B has left
        // since: the last login to arrive wins (#940), and a stale attempt doesn't take the
        // player back. A's place was held until then.
        do {
            let outcome = try await older.value
            Issue.record("the older login was \(outcome), not superseded")
        } catch JoinError.superseded {
            // expected
        }
        try await newerLeaves.value
        let finalCount = await keeper.playerCount()
        #expect(newcomer == .roomIsFull, "the older login's place was given away when the newer login ended")
        #expect(finalCount <= 2, "the land holds more than maxPlayers: players.count == \(finalCount)")
    }

    @Test("a rejoin that succeeded leaves no reservation behind: after the player leaves, its place is free")
    func successfulRejoinReleasesItsReservation() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        let rejoin = Task { try await join(keeper, "p1", client: "p1-b") }
        #expect(await box.gate.waitForArrivals(1))
        box.gate.open()
        #expect(try await rejoin.value == .admitted)
        // p1 leaves (its OnLeave passes the open gate): nobody holds its place any more.
        try await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("p1-b"), sessionID: SessionID("p1-b"))
        #expect(await keeper.playerCount() == 1)
        #expect(try await join(keeper, "p3", client: "p3-a") == .admitted)
        #expect(await keeper.playerCount() == 2)
    }

    @Test("teardown during a kick: a late newcomer is told the land is shutting down, not that it is full")
    func lateNewcomerDuringTeardownGetsShuttingDown() async throws {
        let (keeper, box) = try await makeFullKeeper()
        defer { box.gate.open() }
        let rejoin = Task { _ = try? await join(keeper, "p1", client: "p1-b") }
        #expect(await box.gate.waitForArrivals(1))
        let shutdown = Task { await keeper.forceShutdown() }
        await keeper.waitUntilDrainStartedForTesting()
        do {
            _ = try await join(keeper, "p3", client: "p3-a")
            Issue.record("the join of a draining land was admitted")
        } catch JoinError.landShuttingDown {
            // expected
        } catch {
            Issue.record("expected landShuttingDown, got \(error)")
        }
        box.gate.open()
        await shutdown.value
        await rejoin.value
    }
}
