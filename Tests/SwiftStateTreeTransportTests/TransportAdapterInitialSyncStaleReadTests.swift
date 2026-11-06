// Tests/SwiftStateTreeTransportTests/TransportAdapterInitialSyncStaleReadTests.swift
//
// #98: an initial sync that already read the state when its session disconnected, and the
// player rejoined on a new session whose initial sync then finished, must not commit: no
// frame, no per-player cache, no firstSync mark. Otherwise the new session's diff baseline
// is the old read, and a value that changes A→B→A sends the client nothing for B→A.
//
// Two checks stop it, each enough on its own: the session ticket checked after the state read
// (`_syncStateForNewPlayer`), and a firstSync staging a player's cache only when the player has
// none (`SyncEngine.lateJoinSnapshot`). The drop counter pins the first, the 7→5 diff the second.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct StaleReadTestState: StateNodeProtocol {
    /// Each player sees only its own entry, so its diffs are against its per-player cache.
    @Sync(.perPlayerSlice())
    var scores: [PlayerID: Int] = [:]
}

@Payload
struct StaleReadSetScoreResponse: ResponsePayload {
    let score: Int
}

@Payload
struct StaleReadSetScoreAction: ActionPayload {
    typealias Response = StaleReadSetScoreResponse
    let player: String
    let score: Int
}

/// Records every frame with its target session.
private actor StaleReadTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// The state updates `sessionID` received, in order.
    func updates(for sessionID: SessionID) -> [StateUpdate] {
        frames.compactMap { frame in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            return try? JSONDecoder().decode(StateUpdate.self, from: frame.data)
        }
    }
}

private struct StaleReadFixture {
    let adapter: TransportAdapter<StaleReadTestState>
    let transport: StaleReadTransport

    func join(_ session: SessionID, _ client: ClientID, as player: PlayerID, initialSync: Bool = true) async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        let joined = try #require(try await adapter.performJoin(
            playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, authInfo: nil
        ))
        if initialSync { await adapter.syncStateForNewPlayer(playerID: joined.playerID, sessionID: session) }
    }

    /// Sets `player`'s score from `session`, then runs a sync cycle and waits for its frames.
    func setScore(_ player: PlayerID, _ score: Int, from session: SessionID) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: StaleReadSetScoreAction.self),
            payload: AnyCodable(StaleReadSetScoreAction(player: player.rawValue, score: score))
        )
        let message = TransportMessage.action(requestID: "set-\(player.rawValue)-\(score)", action: envelope)
        await adapter.onMessage(try JSONEncoder().encode(message), from: session)
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain())
    }
}

private func makeFixture(inTurn: Bool) async -> StaleReadFixture {
    let definition = Land("stale-read", using: StaleReadTestState.self) {
        Rules {
            HandleAction(StaleReadSetScoreAction.self) { (state: inout StaleReadTestState, action: StaleReadSetScoreAction, _: LandContext) in
                state.scores[PlayerID(action.player)] = action.score
                return StaleReadSetScoreResponse(score: action.score)
            }
        }
    }
    let transport = StaleReadTransport()
    let keeper = LandKeeper(definition: definition, initialState: StaleReadTestState(), autoStartLoops: false)
    let adapter = TransportAdapter<StaleReadTestState>(
        keeper: keeper, transport: transport, landID: "stale-read", inTurnSync: inTurn
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return StaleReadFixture(adapter: adapter, transport: transport)
}

@Suite("Initial sync with a stale state read (#98)")
struct TransportAdapterInitialSyncStaleReadTests {

    @Test("A disconnect and rejoin while the old initial sync holds its read: the old one commits nothing, the new baseline stands", arguments: [true, false])
    func staleReadAfterRejoin(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        let player = PlayerID("p1"), observer = PlayerID("observer")
        let s0 = SessionID("s0"), s1 = SessionID("s1"), s2 = SessionID("s2")
        try await f.join(s0, ClientID("c0"), as: observer)
        try await f.setScore(player, 5, from: s0)

        // Operation A (S1) reads the state (p1's score is 5) and is held before it commits.
        let afterRead = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.initialSyncAfterRead) { await afterRead.arrive() })
        try await f.join(s1, ClientID("c1"), as: player, initialSync: false)
        let operationA = Task { await f.adapter.syncStateForNewPlayer(playerID: player, sessionID: s1) }
        #expect(await afterRead.waitForArrivals(1))
        await f.adapter.installHolds(nil)

        // S1 disconnects; p1's score changes 5→7; p1 rejoins as S2, whose initial sync reads 7.
        await f.adapter.onDisconnect(sessionID: s1, clientID: ClientID("c1"))
        try await f.setScore(player, 7, from: s0)
        try await f.join(s2, ClientID("c2"), as: player)
        #expect(await f.adapter.isInitialSyncingForTesting(player) == false)
        #expect(await f.adapter.waitForOutboundDrain())
        let s2AfterJoin = await f.transport.updates(for: s2)
        #expect(s2AfterJoin.count == 1, "S2 received \(s2AfterJoin)")

        // A resumes with its old read: it must send nothing and leave S2's state alone.
        afterRead.open()
        await operationA.value
        #expect(await f.adapter.waitForOutboundDrain())
        let s1Updates = await f.transport.updates(for: s1)
        #expect(s1Updates.isEmpty, "A sent \(s1Updates)")
        #expect(await f.adapter.isInitialSyncingForTesting(player) == false)
        #expect(await f.adapter.initialSyncsDroppedStale == 1, "A is dropped by its ticket check")

        // 7→5, back to A's read: S2's client holds 7, so it must get a diff. Had A overwritten
        // p1's cache with its stale read (5), the diff would be empty and S2 would keep 7.
        try await f.setScore(player, 5, from: s0)
        let s2Updates = await f.transport.updates(for: s2)
        let diffs = s2Updates.filter { if case .diff = $0 { return true } else { return false } }
        #expect(diffs.count == 1, "S2 received \(s2Updates)")
        let expected = StateUpdate.diff([StatePatch(path: "/scores/p1", operation: .set(.int(5)))])
        #expect(diffs.first == expected, "S2 received \(s2Updates)")
    }
}
