// Tests/SwiftStateTreeTransportTests/InitialSyncBehindCommitTests.swift
//
// #564: a standalone firstSync (a join not completed in a turn) reads the state, and a sync
// cycle that skips the joiner commits during that read. The cycle moves the shared broadcast
// cache past the read, and the next diff starts from the cache, so a firstSync from the read
// would leave the joiner behind on every broadcast field changed in between, until it changes
// again. The firstSync is dropped instead, and the next cycle sends the joiner its whole view.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct BehindCommitState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0
}

@Payload
struct BehindCommitResponse: ResponsePayload {
    let total: Int
}

@Payload
struct BehindCommitSetTotal: ActionPayload {
    typealias Response = BehindCommitResponse
    let total: Int
}

/// Records every frame with its target session.
private actor BehindCommitTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// The `/total` values `sessionID` received, in order, each with its update's kind.
    func totals(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame -> StateUpdate? in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            return try? JSONDecoder().decode(StateUpdate.self, from: frame.data)
        }.flatMap { update -> [String] in
            let (kind, patches): (String, [StatePatch])
            switch update {
            case .firstSync(let p): (kind, patches) = ("firstSync", p)
            case .diff(let p): (kind, patches) = ("diff", p)
            default: return []
            }
            return patches.compactMap { patch in
                guard patch.path == "/total", case .set(.int(let value)) = patch.operation else { return nil }
                return "\(kind) \(value)"
            }
        }
    }
}

/// A land with periodic sync (a sync loop whose interval the test never reaches; it runs the next
/// cycle itself), or one that syncs only on request. No tick: inputs apply at once on both, and
/// the race is the adapter's, whatever applies the inputs.
private func makeBehindCommitLand(periodic: Bool) -> LandDefinition<BehindCommitState> {
    guard periodic else {
        return Land("behind-commit", using: BehindCommitState.self) {
            Rules { HandleAction(BehindCommitSetTotal.self, setTotal) }
        }
    }
    return Land("behind-commit", using: BehindCommitState.self) {
        Lifetime {
            StateSync(every: .seconds(3600)) { _, _ in }
        }
        Rules { HandleAction(BehindCommitSetTotal.self, setTotal) }
    }
}

@Sendable
private func setTotal(_ state: inout BehindCommitState, _ action: BehindCommitSetTotal, _: LandContext) -> BehindCommitResponse {
    state.total = action.total
    return BehindCommitResponse(total: action.total)
}

@Suite("A firstSync whose state read a sync commit passed (#564)")
struct InitialSyncBehindCommitTests {

    @Test("A cycle commits during a joiner's firstSync read: the joiner gets its whole view from the next cycle", arguments: [true, false])
    func cycleCommitsDuringFirstSyncRead(periodic: Bool) async throws {
        let definition = makeBehindCommitLand(periodic: periodic)
        let transport = BehindCommitTransport()
        let keeper = LandKeeper(definition: definition, initialState: BehindCommitState(), autoStartLoops: periodic)
        let adapter = TransportAdapter<BehindCommitState>(
            keeper: keeper, transport: transport, landID: "behind-commit"
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        // The join-commit observations record only in DEBUG builds (#748); the rest runs in release too.
        #if DEBUG
        await adapter.captureJoinCommitsForTesting()
        typealias Key = TransportAdapter<BehindCommitState>.JoinAttemptKey
        #endif
        #expect(keeper.hasPeriodicSync == periodic)

        let observer = (session: SessionID("s0"), client: ClientID("c0"), player: PlayerID("observer"))
        let joiner = (session: SessionID("s1"), client: ClientID("c1"), player: PlayerID("p1"))
        func connect(_ who: (session: SessionID, client: ClientID, player: PlayerID)) async throws {
            await adapter.onConnect(sessionID: who.session, clientID: who.client)
            _ = try #require(try await adapter.performJoin(
                playerSession: PlayerSession(playerID: who.player.rawValue, deviceID: "dev", metadata: [:]),
                clientID: who.client, sessionID: who.session, authInfo: nil, joinAttempt: 1
            ))
        }
        func setTotal(_ total: Int) async throws {
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: BehindCommitSetTotal.self),
                payload: AnyCodable(BehindCommitSetTotal(total: total))
            )
            let message = TransportMessage.action(requestID: "set-\(total)", action: envelope)
            await adapter.onMessage(try JSONEncoder().encode(message), from: observer.session)
            await adapter.syncNow()
            #expect(await adapter.waitForSyncQuiescenceForTesting())
        }

        try await connect(observer)
        await adapter.syncStateForNewPlayer(playerID: observer.player, sessionID: observer.session)
        try await setTotal(3)

        // The joiner's firstSync reads the state (total 3) and is held before it commits.
        let afterRead = TestGate()
        await adapter.installHolds(HoldRegistry.at(.initialSyncAfterRead) { await afterRead.arrive() })
        try await connect(joiner)
        let firstSync = Task { await adapter.syncStateForNewPlayer(playerID: joiner.player, sessionID: joiner.session) }
        #expect(await afterRead.waitForArrivals(1))
        await adapter.installHolds(nil)

        // A cycle commits meanwhile: it skips the joiner and moves the broadcast cache to 7.
        try await setTotal(7)
        let observerTotals = await transport.totals(for: observer.session)
        #expect(observerTotals == ["firstSync 0", "diff 3", "diff 7"], "the observer received \(observerTotals)")

        let followUps = TestGate()
        await adapter.installHolds(HoldRegistry.at(.failedPlanFollowUp) { await followUps.arrive() })
        afterRead.open()
        await firstSync.value
        #expect(await adapter.initialSyncsDroppedBehindCommit == 1)
        #expect(await adapter.initialSyncsDroppedStale == 0)
        #expect(await transport.totals(for: joiner.session).isEmpty, "the firstSync from the passed read was sent")
        // The named observation (#555): the dropped firstSync committed nothing for the joiner.
        #if DEBUG
        #expect(await !adapter.initialSyncCommittedForTesting(Key(sessionID: joiner.session, attempt: 1)))
        #expect(await adapter.initialSyncCommittedForTesting(Key(sessionID: observer.session, attempt: 1)))
        #endif

        if periodic {
            // The next periodic cycle.
            await adapter.syncNow()
        } else {
            // No periodic sync: the follow-up runs the next cycle, one requested sync-only turn
            // (#546 L2a).
            #expect(await followUps.waitForArrivals(1), "no follow-up cycle started")
            followUps.open()
        }

        // The follow-up is a background sync, which this wait covers, with the writer's drain.
        #expect(await adapter.waitForSyncQuiescenceForTesting())
        if !periodic {
            #expect(await keeper.requestedSyncTurnsForTesting[.behindCommitRepair, default: 0] == 1)
        }
        let joinerTotals = await transport.totals(for: joiner.session)
        #expect(joinerTotals == ["firstSync 7"], "the joiner received \(joinerTotals)")
        // The cycle's full view for the unsynced joiner is its initial sync.
        #if DEBUG
        #expect(await adapter.initialSyncCommittedForTesting(Key(sessionID: joiner.session, attempt: 1)))
        #expect(await !adapter.initialSyncCommittedForTesting(Key(sessionID: joiner.session, attempt: nil)), "keyed by the attempt")
        #endif
        let observerAfter = await transport.totals(for: observer.session)
        #expect(observerAfter == ["firstSync 0", "diff 3", "diff 7"], "the observer received \(observerAfter)")
        await adapter.installHolds(nil)
    }
}
