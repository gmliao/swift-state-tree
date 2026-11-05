// Tests/SwiftStateTreeTransportTests/TransportAdapterNewestWinsTests.swift
//
// One session per player, newest wins (#92): a join of a player that has a session supersedes
// it in the admission segment (the keeper's join already ran OnLeave, then OnJoin). The old
// session leaves the membership and is closed; the keeper rejects its inputs once the player's
// entry is the new session's; its later disconnect clears nothing.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct NewestWinsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
    @Sync(.broadcast)
    var leaves: Int = 0
    @Sync(.broadcast)
    var bumps: Int = 0
}

@Payload
struct NewestWinsBumpResponse: ResponsePayload {
    let bumps: Int
}

@Payload
struct NewestWinsBumpAction: ActionPayload {
    typealias Response = NewestWinsBumpResponse
    let by: Int
}

/// Gates for OnJoin resolvers, by client ID: a join from a registered client is held at its
/// gate. One gate per test case, so parallel cases don't release each other's joins.
private final class NewestWinsJoinHold: @unchecked Sendable {
    static let shared = NewestWinsJoinHold()
    private let lock = NSLock()
    private var gates: [ClientID: TestGate] = [:]

    func register(_ client: ClientID) -> TestGate {
        lock.lock(); defer { lock.unlock() }
        let gate = TestGate()
        gates[client] = gate
        return gate
    }

    func gate(for client: ClientID) -> TestGate? {
        lock.lock(); defer { lock.unlock() }
        return gates[client]
    }
}

struct NewestWinsJoinResolver: ContextResolver {
    typealias Output = NewestWinsJoinOutput

    static func resolve(ctx: ResolverContext) async throws -> NewestWinsJoinOutput {
        if let gate = NewestWinsJoinHold.shared.gate(for: ctx.clientID) {
            await gate.arrive()
        }
        return NewestWinsJoinOutput()
    }
}

struct NewestWinsJoinOutput: ResolverOutput {}

@Payload
struct NewestWinsHeldBumpAction: ActionPayload {
    typealias Response = NewestWinsBumpResponse
    let by: Int
}

/// Holds the resolver of a held bump from a client registered with `NewestWinsActionHold`.
private enum NewestWinsActionHold {
    static let gates = NewestWinsJoinHold()
}

struct NewestWinsActionResolver: ContextResolver {
    typealias Output = NewestWinsActionOutput

    static func resolve(ctx: ResolverContext) async throws -> NewestWinsActionOutput {
        if let gate = NewestWinsActionHold.gates.gate(for: ctx.clientID) {
            await gate.arrive()
        }
        return NewestWinsActionOutput()
    }
}

struct NewestWinsActionOutput: ResolverOutput {}

/// Records frames (in send order) and closed sessions.
private actor NewestWinsTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []
    private(set) var closed: [SessionID] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append((message, target))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    func closeSession(_ sessionID: SessionID) async { closed.append(sessionID) }
    nonisolated var supportsCloseSession: Bool { true }

    /// What `sessionID` received, in order: "joinResponse", "actionResponse", "error",
    /// "firstSync", "diff", "noChange" or "other".
    func kinds(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            let decoder = JSONDecoder()
            if let message = try? decoder.decode(TransportMessage.self, from: frame.data) {
                switch message.kind {
                case .joinResponse: return "joinResponse"
                case .actionResponse: return "actionResponse"
                case .error: return "error"
                default: return "other"
                }
            }
            if let update = try? decoder.decode(StateUpdate.self, from: frame.data) {
                switch update {
                case .noChange: return "noChange"
                case .firstSync: return "firstSync"
                case .diff: return "diff"
                }
            }
            return "other"
        }
    }
}

private struct NewestWinsFixture {
    let keeper: LandKeeper<NewestWinsTestState>
    let adapter: TransportAdapter<NewestWinsTestState>
    let transport: NewestWinsTransport

    func connect(_ session: SessionID, _ client: ClientID) async {
        await adapter.onConnect(sessionID: session, clientID: client)
    }

    /// The router's join: admission, then the initial sync.
    @discardableResult
    func join(_ session: SessionID, _ client: ClientID, as player: PlayerID) async throws -> TransportAdapter<NewestWinsTestState>.JoinResult {
        let result = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil
        )
        let joined = try #require(result)
        await adapter.syncStateForNewPlayer(playerID: joined.playerID, sessionID: session)
        return joined
    }

    /// A bump action sent by the client of `session`.
    func bump(from session: SessionID, by: Int = 1) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: NewestWinsBumpAction.self),
            payload: AnyCodable(NewestWinsBumpAction(by: by))
        )
        let message = TransportMessage.action(requestID: "bump-\(session.rawValue)-\(by)", action: envelope)
        await adapter.onMessage(try JSONEncoder().encode(message), from: session)
    }
}

private func makeFixture(inTurn: Bool, legacyJoin: Bool = false, mode: LandMode = .live) async -> NewestWinsFixture {
    let definition = Land("newest-wins", using: NewestWinsTestState.self) {
        Rules {
            OnJoin(resolvers: NewestWinsJoinResolver.self) { (state: inout NewestWinsTestState, _: LandContext) in
                state.joins += 1
            }
            OnLeave { (state: inout NewestWinsTestState, _: LandContext) in
                state.leaves += 1
            }
            HandleAction(NewestWinsBumpAction.self) { (state: inout NewestWinsTestState, action: NewestWinsBumpAction, _: LandContext) in
                state.bumps += action.by
                return NewestWinsBumpResponse(bumps: state.bumps)
            }
            HandleAction(NewestWinsHeldBumpAction.self, resolvers: NewestWinsActionResolver.self) {
                (state: inout NewestWinsTestState, action: NewestWinsHeldBumpAction, _: LandContext) in
                state.bumps += action.by
                return NewestWinsBumpResponse(bumps: state.bumps)
            }
        }
    }
    let transport = NewestWinsTransport()
    let keeper = LandKeeper(
        definition: definition,
        initialState: NewestWinsTestState(),
        mode: mode,
        autoStartLoops: false
    )
    let adapter = TransportAdapter<NewestWinsTestState>(
        keeper: keeper,
        transport: transport,
        landID: "newest-wins",
        enableLegacyJoin: legacyJoin,
        inTurnSync: inTurn
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return NewestWinsFixture(keeper: keeper, adapter: adapter, transport: transport)
}

@Suite("One session per player, newest wins (#92)")
struct TransportAdapterNewestWinsTests {
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")
    let s2 = SessionID("s2"), c2 = ClientID("c2")

    @Test("A second join of the player supersedes the first session: one member, the old one closed", arguments: [true, false])
    func secondJoinSupersedesFirst(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        await f.connect(s1, c1)
        let first = try await f.join(s1, c1, as: player)
        await f.connect(s2, c2)
        let second = try await f.join(s2, c2, as: player)

        #expect(second.playerSlot == first.playerSlot, "the slot is kept")
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await f.adapter.supersededSessionCount == 1)
        #expect(await pollUntilAsync { await f.transport.closed == [s1] })
        // The keeper: OnLeave for the old entry, then OnJoin for the new one.
        let state = await f.keeper.currentState()
        #expect(state.joins == 2 && state.leaves == 1)
        #expect(await f.keeper.playerCount() == 1)

        // From the kick on, only the new session gets frames; its first is the firstSync.
        let s1Frames = await f.transport.kinds(for: s1).count
        try await f.bump(from: s2)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.transport.kinds(for: s1).count == s1Frames)
        let s2Kinds = await f.transport.kinds(for: s2)
        #expect(s2Kinds.first == "firstSync", "\(s2Kinds)")
        #expect(s2Kinds.contains("diff"), "\(s2Kinds)")
        #expect(await f.keeper.currentState().bumps == 1)

        // The old session's disconnect, when it comes, clears nothing and leaves nothing.
        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await f.adapter.getPlayerSlot(for: player) == first.playerSlot)
        #expect(await f.adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(player))
        #expect(await f.keeper.playerCount() == 1)
        #expect(await f.keeper.currentState().leaves == 1)
    }

    @Test("A reconnect from the same client supersedes the old session; the old one's input is rejected", arguments: [true, false])
    func sameClientReconnectSupersedes(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        await f.connect(s1, c1)
        try await f.join(s1, c1, as: player)
        await f.connect(s2, c1)
        try await f.join(s2, c1, as: player)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])

        // The keeper's entry is the new session: an input as the old session is rejected, by
        // session (the client ID is the same).
        await #expect(throws: LandInputRejection.self) {
            _ = try await f.keeper.handleActionEnvelope(
                ActionEnvelope(
                    typeIdentifier: String(describing: NewestWinsBumpAction.self),
                    payload: AnyCodable(NewestWinsBumpAction(by: 1))
                ),
                playerID: player, clientID: c1, sessionID: s1
            )
        }
        #expect(await f.keeper.supersededSenderRejections == 1)
        #expect(await f.keeper.currentState().bumps == 0)
    }

    @Test("The old session's action between the keeper's kick and the admission is rejected", arguments: [true, false])
    func oldSessionActionInKickToAdmissionGap(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        let held = ClientID("held-client-\(inTurn)")
        let gate = NewestWinsJoinHold.shared.register(held)
        await f.connect(s1, c1)
        try await f.join(s1, c1, as: player)

        // The second join is held in its OnJoin resolver: the keeper has left the old entry and
        // inserted the new one, the adapter hasn't admitted it yet (in-turn it admits at the
        // OnJoin input's append, after the resolvers), so S1 is still the member and its action
        // reaches the keeper, whose intake rejects it.
        await f.connect(s2, held)
        let second = Task { try await f.join(s2, held, as: player) }
        #expect(await gate.waitForArrivals(1))
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s1])
        try await f.bump(from: s1)
        #expect(await f.keeper.supersededSenderRejections == 1)
        #expect(await f.keeper.currentState().bumps == 0)

        gate.open()
        _ = try await second.value
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        try await f.bump(from: s2)
        #expect(await pollUntilAsync { await f.keeper.currentState().bumps == 1 })
    }

    @Test("An action whose resolver awaits across the kick is rejected, not applied to the new session", arguments: [true, false])
    func actionHeldAcrossKickIsRejected(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        let oldClient = ClientID("held-action-client-\(inTurn)")
        let gate = NewestWinsActionHold.gates.register(oldClient)
        await f.connect(s1, oldClient)
        try await f.join(s1, oldClient, as: player)

        // S1's action passes the intake check and is held in its resolver.
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: NewestWinsHeldBumpAction.self),
            payload: AnyCodable(NewestWinsHeldBumpAction(by: 5))
        )
        let action = Task {
            try await f.keeper.handleActionEnvelope(envelope, playerID: player, clientID: oldClient, sessionID: s1)
        }
        #expect(await gate.waitForArrivals(1))

        // Meanwhile S2 joins (OnLeave, OnJoin), is admitted and supersedes S1.
        await f.connect(s2, c2)
        try await f.join(s2, c2, as: player)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])

        // Released, the action is rejected in its append segment: S2's state is untouched.
        gate.open()
        await #expect(throws: LandInputRejection.senderSuperseded) { _ = try await action.value }
        #expect(await f.keeper.supersededSenderRejections == 1)
        #expect(await f.keeper.currentState().bumps == 0)
    }

    @Test("Legacy join: the second join supersedes the first, OnLeave runs once", arguments: [true, false])
    func legacyJoinSupersedes(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn, legacyJoin: true)
        for (session, client) in [(s1, c1), (s2, c2)] {
            await f.connect(session, client)
            let join = TransportMessage.join(
                requestID: "join-\(session.rawValue)",
                landType: "newest-wins",
                landInstanceId: nil,
                playerID: player.rawValue,
                deviceID: "dev",
                metadata: nil
            )
            await f.adapter.onMessage(try JSONEncoder().encode(join), from: session)
            #expect(await pollUntilAsync { await f.transport.kinds(for: session).contains("firstSync") })
        }
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await pollUntilAsync { await f.transport.closed == [s1] })
        let state = await f.keeper.currentState()
        #expect(state.joins == 2 && state.leaves == 1)
        #expect(await f.keeper.playerCount() == 1)
    }

    @Test("Direct-caller intake is unchanged: a join then sends, an absent player, the system player, a replay keeper")
    func directCallerIntakeUnchanged() async throws {
        let f = await makeFixture(inTurn: false)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: NewestWinsBumpAction.self),
            payload: AnyCodable(NewestWinsBumpAction(by: 1))
        )
        // A join, then sends with the same client and session.
        _ = try await f.keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: c1, sessionID: s1, services: LandServices()
        )
        _ = try await f.keeper.handleActionEnvelope(envelope, playerID: player, clientID: c1, sessionID: s1)
        // A player with no entry.
        _ = try await f.keeper.handleActionEnvelope(envelope, playerID: PlayerID("never-joined"), clientID: c2, sessionID: s2)
        // The system player.
        _ = try await f.keeper.handleActionEnvelope(
            envelope,
            playerID: LandContext.systemPlayerID,
            clientID: LandContext.systemClientID,
            sessionID: LandContext.systemSessionID
        )
        #expect(await pollUntilAsync { await f.keeper.currentState().bumps == 3 })
        #expect(await f.keeper.supersededSenderRejections == 0)

        // Another client or another session than the entry's is rejected.
        await #expect(throws: LandInputRejection.self) {
            _ = try await f.keeper.handleActionEnvelope(envelope, playerID: player, clientID: c2, sessionID: s1)
        }
        await #expect(throws: LandInputRejection.self) {
            _ = try await f.keeper.handleActionEnvelope(envelope, playerID: player, clientID: c1, sessionID: s2)
        }
        #expect(await f.keeper.supersededSenderRejections == 2)

        // A replay keeper takes no transport inputs at all, and rejects nothing.
        let replay = await makeFixture(inTurn: false, mode: .reevaluation)
        _ = try await replay.keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: c1, sessionID: s1, services: LandServices()
        )
        _ = try await replay.keeper.handleActionEnvelope(envelope, playerID: player, clientID: c2, sessionID: s2)
        #expect(await replay.keeper.supersededSenderRejections == 0)
    }

    @Test("leave with a session leaves only that session's entry")
    func leaveChecksSession() async throws {
        let f = await makeFixture(inTurn: false)
        _ = try await f.keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: c1, sessionID: s1, services: LandServices()
        )
        try await f.keeper.leave(playerID: player, clientID: c1, sessionID: s2)
        #expect(await f.keeper.playerCount() == 1, "another session with a colliding client ID")
        try await f.keeper.leave(playerID: player, clientID: c1, sessionID: s1)
        #expect(await f.keeper.playerCount() == 0)
    }

    @Test("An older initial sync finishing after the newer one started doesn't clear the newer one's mark", arguments: [true, false])
    func olderInitialSyncKeepsNewerMark(inTurn: Bool) async throws {
        let f = await makeFixture(inTurn: inTurn)
        let observer = PlayerID("observer")
        let s0 = SessionID("s0"), c0 = ClientID("c0")
        await f.connect(s0, c0)
        try await f.join(s0, c0, as: observer)

        // S1's initial sync is held at its state read (first hold); S2's at its own (second).
        let firstHold = TestGate(), secondHold = TestGate()
        let holds = HoldSequence([firstHold, secondHold])
        await f.adapter.installHolds(HoldRegistry.at(.initialSync) { await holds.next() })

        await f.connect(s1, c1)
        let firstJoin = try #require(try await f.adapter.performJoin(
            playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: c1, sessionID: s1, authInfo: nil
        ))
        let firstSync = Task { await f.adapter.syncStateForNewPlayer(playerID: firstJoin.playerID, sessionID: s1) }
        #expect(await firstHold.waitForArrivals(1))

        // S2 supersedes S1 and starts its initial sync (marked, held).
        await f.connect(s2, c2)
        let secondJoin = try #require(try await f.adapter.performJoin(
            playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: c2, sessionID: s2, authInfo: nil
        ))
        let secondSync = Task { await f.adapter.syncStateForNewPlayer(playerID: secondJoin.playerID, sessionID: s2) }
        #expect(await secondHold.waitForArrivals(1))

        // S1's initial sync finishes (dropped: S1 left). The player is still marked for S2.
        firstHold.open()
        await firstSync.value
        #expect(await f.adapter.isInitialSyncingForTesting(player))

        // A sync now must not reach S2 before its firstSync.
        try await f.bump(from: s0)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        let early = await f.transport.kinds(for: s2)
        #expect(early.isEmpty, "\(early)")

        secondHold.open()
        await secondSync.value
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.transport.kinds(for: s2).first == "firstSync")
    }
}

/// Hands out one gate per call, in order; later calls pass.
private final class HoldSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [TestGate]
    init(_ gates: [TestGate]) { self.gates = gates }

    func next() async {
        await take()?.arrive()
    }

    private func take() -> TestGate? {
        lock.lock()
        defer { lock.unlock() }
        return gates.isEmpty ? nil : gates.removeFirst()
    }
}

/// Polls an async `condition` every 5 ms for up to 5 s; returns its final value.
private func pollUntilAsync(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
