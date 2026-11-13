// Tests/SwiftStateTreeTransportTests/TransportAdapterRegisterSessionTests.swift
//
// The public `registerSession` follows the realtime adapter's rule, newest wins (#531): it runs
// in the membership queue, supersedes the player's older sessions, refuses a registration whose
// session the keeper's entry doesn't name, and records the connection generation under a ticket.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct RegisterSessionTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
    @Sync(.broadcast)
    var leaves: Int = 0
    @Sync(.broadcast)
    var bumps: Int = 0
}

@Payload
struct RegisterSessionBumpResponse: ResponsePayload {
    let bumps: Int
}

@Payload
struct RegisterSessionBumpAction: ActionPayload {
    typealias Response = RegisterSessionBumpResponse
    let by: Int
}

/// Records closed sessions; `closeSignal` counts the closes as arrivals.
private actor RegisterSessionTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var closed: [SessionID] = []
    let closeSignal = TestGate()

    init() { closeSignal.open() }

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func closeSession(_ sessionID: SessionID) async {
        closed.append(sessionID)
        await closeSignal.arrive()
    }
    nonisolated var supportsCloseSession: Bool { true }
}

private struct RegisterSessionFixture {
    let keeper: LandKeeper<RegisterSessionTestState>
    let adapter: TransportAdapter<RegisterSessionTestState>
    let transport: RegisterSessionTransport

    init(inTurn: Bool = false, mode: LandMode = .live) async {
        let definition = Land("register-session", using: RegisterSessionTestState.self) {
            Rules {
                OnJoin { (state: inout RegisterSessionTestState, _: LandContext) in
                    state.joins += 1
                }
                OnLeave { (state: inout RegisterSessionTestState, _: LandContext) in
                    state.leaves += 1
                }
                HandleAction(RegisterSessionBumpAction.self) {
                    (state: inout RegisterSessionTestState, action: RegisterSessionBumpAction, _: LandContext) in
                    state.bumps += action.by
                    return RegisterSessionBumpResponse(bumps: state.bumps)
                }
            }
        }
        transport = RegisterSessionTransport()
        keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), mode: mode, autoStartLoops: false)
        adapter = TransportAdapter<RegisterSessionTestState>(
            keeper: keeper, transport: transport, landID: "register-session", inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
    }

    /// A host's keeper join, without the adapter.
    func keeperJoin(_ session: SessionID, _ client: ClientID, as player: PlayerID) async throws {
        let decision = try await keeper.join(
            session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, services: LandServices()
        )
        guard case .allow = decision else {
            Issue.record("keeper join of \(session.rawValue) denied")
            return
        }
    }

    /// A host's registration of a session it joined in the keeper.
    func register(_ session: SessionID, _ client: ClientID, as player: PlayerID, generation: UInt64? = nil) async {
        await adapter.onConnect(sessionID: session, clientID: client)
        await adapter.registerSession(
            sessionID: session, clientID: client, playerID: player, authInfo: nil, connectionGeneration: generation
        )
    }

    /// The library's join (the router's path): keeper join and admission in the membership queue.
    func libraryJoin(_ session: SessionID, _ client: ClientID, as player: PlayerID) async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, authInfo: nil
        )
        _ = try #require(result)
    }

    /// A bump sent to the keeper as the client and session given. Throws when the keeper's
    /// sender check rejects it.
    func bump(as player: PlayerID, _ client: ClientID, _ session: SessionID) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: RegisterSessionBumpAction.self),
            payload: AnyCodable(RegisterSessionBumpAction(by: 1))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }

    func entrySessionID(of player: PlayerID) async -> SessionID? {
        await keeper.entrySession(for: player)?.sessionID ?? nil
    }

    /// Waits for `count` closes, then returns the closed sessions.
    func closes(_ count: Int) async -> [SessionID]? {
        guard await transport.closeSignal.waitForArrivals(count) else { return nil }
        return await transport.closed
    }

    /// Installs adapter holds whose `.membershipQueued` arrivals pass an open gate, and returns
    /// the gate: its `waitForArrivals(n)` is the n-th membership operation queued since.
    func queuedSignal(on holds: HoldRegistry<TransportAdapterHoldPoint> = HoldRegistry()) async -> TestGate {
        let queued = TestGate()
        queued.open()
        holds.on(.membershipQueued) { await queued.arrive() }
        await adapter.installHolds(holds.hook)
        return queued
    }
}

@Suite("registerSession follows newest wins and the keeper's entry (#531)")
struct TransportAdapterRegisterSessionTests {
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")
    let s2 = SessionID("s2"), c2 = ClientID("c2")
    let s3 = SessionID("s3"), c3 = ClientID("c3")

    @Test("A host's second keeper join and registration supersede the first session: one member, OnJoin twice, OnLeave once", arguments: [true, false])
    func secondRegistrationSupersedes(inTurn: Bool) async throws {
        let f = await RegisterSessionFixture(inTurn: inTurn)
        try await f.keeperJoin(s1, c1, as: player)
        await f.register(s1, c1, as: player)
        try await f.keeperJoin(s2, c2, as: player)
        await f.register(s2, c2, as: player)

        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await f.adapter.supersededSessionCount == 1)
        #expect(await f.adapter.staleRegistrationRefusals == 0)
        #expect(await f.closes(1) == [s1])
        // The supersede is adapter-only: OnJoin and OnLeave are the keeper joins' own.
        let state = await f.keeper.currentState()
        #expect(state.joins == 2 && state.leaves == 1)
        try await f.bump(as: player, c2, s2)
        #expect(await f.keeper.currentState().bumps == 1)
    }

    @Test("A registration without its own keeper join is refused while the entry names another session: OnJoin once, OnLeave zero")
    func registrationWithoutKeeperJoinRefused() async throws {
        let f = await RegisterSessionFixture()
        try await f.keeperJoin(s1, c1, as: player)
        await f.register(s1, c1, as: player)
        await f.register(s2, c2, as: player)

        #expect(await f.adapter.membershipSessionIDs(for: player) == [s1])
        #expect(await f.adapter.staleRegistrationRefusals == 1)
        #expect(await f.closes(1) == [s2])
        let state = await f.keeper.currentState()
        #expect(state.joins == 1 && state.leaves == 0)
    }

    @Test("In reevaluation mode the same two-join path runs OnJoin and OnLeave zero times")
    func reevaluationModeRunsNoLifecycleHandlers() async throws {
        let f = await RegisterSessionFixture(mode: .reevaluation)
        try await f.keeperJoin(s1, c1, as: player)
        await f.register(s1, c1, as: player)
        try await f.keeperJoin(s2, c2, as: player)
        await f.register(s2, c2, as: player)

        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        let state = await f.keeper.currentState()
        #expect(state.joins == 0 && state.leaves == 0)
    }

    @Test("A host registration that lost to a library join is refused: the adapter and the keeper both keep the newer session", arguments: [true, false])
    func hostRegistrationLosingToLibraryJoinRefused(inTurn: Bool) async throws {
        let f = await RegisterSessionFixture(inTurn: inTurn)
        // 1. The host joins S2 in the keeper and hasn't registered it yet.
        try await f.keeperJoin(s2, c2, as: player)
        // 2. The library joins S3 through the queue: the keeper and the adapter name S3.
        try await f.libraryJoin(s3, c3, as: player)
        #expect(await f.entrySessionID(of: player) == s3)
        // 3. The host registers S2.
        await f.register(s2, c2, as: player)

        #expect(await f.adapter.membershipSessionIDs(for: player) == [s3])
        #expect(await f.entrySessionID(of: player) == s3)
        #expect(await f.adapter.staleRegistrationRefusals == 1)
        #expect(await f.closes(1) == [s2])
        try await f.bump(as: player, c3, s3)
        #expect(await f.keeper.currentState().bumps == 1)
    }

    @Test("A keeper join after the registration's keeper read leaves a transient mismatch, which the newer registration ends")
    func keeperJoinAfterTheReadIsTransient() async throws {
        let f = await RegisterSessionFixture()
        try await f.keeperJoin(s2, c2, as: player)

        let gate = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
        holds.on(.registrationAfterKeeperRead, arrival: 1) { await gate.arrive() }
        await f.adapter.installHolds(holds.hook)
        let registration = Task { await f.register(s2, c2, as: player) }
        #expect(await gate.waitForArrivals(1))
        // The read returned S2's entry; the host's keeper join of S3 moves it now.
        try await f.keeperJoin(s3, c3, as: player)
        gate.open()
        await registration.value

        // Transient: the adapter committed S2, the keeper names S3, and S2's input is rejected.
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await f.entrySessionID(of: player) == s3)
        await #expect(throws: LandInputRejection.self) { try await f.bump(as: player, c2, s2) }

        // The host registers S3: its check passes, S2 is superseded, and both name S3.
        await f.register(s3, c3, as: player)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s3])
        #expect(await f.entrySessionID(of: player) == s3)
        #expect(await f.closes(1) == [s2])
        try await f.bump(as: player, c3, s3)
        #expect(await f.keeper.currentState().bumps == 1)
    }

    @Test("A registration issued while a library join holds the membership queue runs after it")
    func registrationWaitsForQueuedJoin() async throws {
        let f = await RegisterSessionFixture()
        let joinGate = TestGate()
        await f.keeper.installHolds(HoldRegistry.at(.join) { await joinGate.arrive() })

        let join = Task { try await f.libraryJoin(s1, c1, as: player) }
        #expect(await joinGate.waitForArrivals(1))
        let adapterHolds = HoldRegistry<TransportAdapterHoldPoint>()
        let queued = await f.queuedSignal(on: adapterHolds)
        let registration = Task { await f.register(s2, c2, as: player) }
        // The registration is queued behind the held join, so it can't have run.
        #expect(await queued.waitForArrivals(1))
        #expect(adapterHolds.arrivalCount(at: .registrationAfterKeeperRead) == 0)
        #expect(await f.adapter.membershipSessionIDs(for: player).isEmpty)

        joinGate.open()
        try await join.value
        await registration.value
        // The registration ran after the join: the keeper's entry named S1, so S2 was refused.
        #expect(adapterHolds.arrivalCount(at: .registrationAfterKeeperRead) == 1)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s1])
        #expect(await f.adapter.staleRegistrationRefusals == 1)
    }

    @Test("A registration issued while a disconnect holds the queue at keeper.leave runs after the leave")
    func registrationWaitsForQueuedDisconnect() async throws {
        let f = await RegisterSessionFixture()
        try await f.libraryJoin(s1, c1, as: player)
        let leaveGate = TestGate()
        await f.keeper.installHolds(HoldRegistry.at(.leave) { await leaveGate.arrive() })

        let disconnect = Task { await f.adapter.onDisconnect(sessionID: s1, clientID: c1) }
        #expect(await leaveGate.waitForArrivals(1))
        let adapterHolds = HoldRegistry<TransportAdapterHoldPoint>()
        let queued = await f.queuedSignal(on: adapterHolds)
        let registration = Task { await f.register(s2, c2, as: player) }
        #expect(await queued.waitForArrivals(1))
        #expect(adapterHolds.arrivalCount(at: .registrationAfterKeeperRead) == 0)

        leaveGate.open()
        await disconnect.value
        await registration.value
        // The leave removed the entry first, so the registration found none and registered S2.
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s2])
        #expect(await f.adapter.staleRegistrationRefusals == 0)
    }

    @Test("A teardown during the registration's generation step leaves no generation for the session")
    func endedTicketDropsTheGenerationWrite() async throws {
        for teardown in [true, false] {
            let f = await RegisterSessionFixture()
            try await f.keeperJoin(s1, c1, as: player)
            let gate = TestGate()
            let holds = HoldRegistry<TransportAdapterHoldPoint>()
            holds.on(.registrationGeneration, arrival: 1) { await gate.arrive() }
            await f.adapter.installHolds(holds.hook)

            let registration = Task { await f.register(s1, c1, as: player, generation: 7) }
            #expect(await gate.waitForArrivals(1))
            // Ended without the queue, which the registration holds.
            if teardown { await f.adapter.endSessionTicketsForTeardown() }
            gate.open()
            await registration.value

            let generation = await f.adapter.connectionGenerations[s1]
            #expect(generation == (teardown ? nil : 7), "teardown: \(teardown)")
        }
    }

    @Test(
        "A teardown during the registration's keeper read: nothing is registered, refused or closed, and no generation comes back",
        arguments: [false, true]
    )
    func teardownDuringKeeperReadRegistersNothing(entryNamesAnother: Bool) async throws {
        let f = await RegisterSessionFixture()
        // The keeper's entry names S1 (registered) or S2 itself (would register).
        if entryNamesAnother {
            try await f.keeperJoin(s1, c1, as: player)
            await f.register(s1, c1, as: player)
        } else {
            try await f.keeperJoin(s2, c2, as: player)
        }
        let gate = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
        // Installed after the setup: the first read is S2's.
        holds.on(.registrationAfterKeeperRead, arrival: 1) { await gate.arrive() }
        await f.adapter.installHolds(holds.hook)

        let registration = Task { await f.register(s2, c2, as: player, generation: 7) }
        #expect(await gate.waitForArrivals(1))
        // Outside the membership queue, which the registration holds.
        await f.adapter.endSessionTicketsForTeardown()
        gate.open()
        await registration.value

        #expect(await f.adapter.membershipSessionIDs(for: player) == (entryNamesAnother ? [s1] : []))
        #expect(await f.adapter.connectionGenerations[s2] == nil)
        #expect(await f.adapter.staleRegistrationRefusals == 0)
        #expect(await f.adapter.supersededSessionCount == 0)
        #expect(await f.transport.closed.isEmpty)
    }

    @Test("Two queued registrations that rebind one session: the later one wins")
    func queuedRebindsLaterWins() async throws {
        let f = await RegisterSessionFixture()
        let p2 = PlayerID("p2"), p3 = PlayerID("p3")
        await f.register(s1, c1, as: player)
        let gate = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
        holds.on(.registrationAfterKeeperRead, arrival: 1) { await gate.arrive() }
        let queued = await f.queuedSignal(on: holds)

        // Both are enqueued with the session's ticket; the first renews it when it rebinds.
        let toP2 = Task {
            await f.adapter.registerSession(sessionID: s1, clientID: c1, playerID: p2, authInfo: nil, connectionGeneration: 5)
        }
        #expect(await gate.waitForArrivals(1))
        let toP3 = Task {
            await f.adapter.registerSession(sessionID: s1, clientID: c1, playerID: p3, authInfo: nil, connectionGeneration: 6)
        }
        #expect(await queued.waitForArrivals(2))
        gate.open()
        await toP2.value
        await toP3.value

        #expect(await f.adapter.membershipSessionIDs(for: p3) == [s1])
        #expect(await f.adapter.membershipSessionIDs(for: p2).isEmpty)
        #expect(await f.adapter.membershipSessionIDs(for: player).isEmpty)
        #expect(await f.adapter.connectionGenerations[s1] == 6)
    }

    @Test(
        "A refused registration doesn't end the ticket under a later one of the session queued with it; the last refused one ends it",
        arguments: [false, true]
    )
    func refusedRegistrationLeavesQueuedOneItsTicket(laterRefusedToo: Bool) async throws {
        let f = await RegisterSessionFixture()
        let p2 = PlayerID("p2")
        // The keeper's entry for `player` names S2, so S1's registration as `player` is refused.
        try await f.keeperJoin(s2, c2, as: player)
        if laterRefusedToo { try await f.keeperJoin(s3, c3, as: p2) }
        await f.adapter.onConnect(sessionID: s1, clientID: c1)
        let gate = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
        holds.on(.registrationAfterKeeperRead, arrival: 1) { await gate.arrive() }
        let queued = await f.queuedSignal(on: holds)

        // R1 issues S1's ticket at its enqueue; R2, queued behind it, holds the same ticket.
        let r1 = Task {
            await f.adapter.registerSession(sessionID: s1, clientID: c1, playerID: player, authInfo: nil, connectionGeneration: 5)
        }
        #expect(await gate.waitForArrivals(1))
        let r2 = Task {
            await f.adapter.registerSession(sessionID: s1, clientID: c1, playerID: p2, authInfo: nil, connectionGeneration: 6)
        }
        #expect(await queued.waitForArrivals(2))
        gate.open()
        await r1.value
        await r2.value

        if laterRefusedToo {
            #expect(await f.adapter.staleRegistrationRefusals == 2)
            #expect(await f.adapter.membershipSessionIDs(for: p2).isEmpty)
            #expect(await !f.adapter.hasSessionTicketForTesting(s1), "the last holder ends the ticket")
        } else {
            #expect(await f.adapter.staleRegistrationRefusals == 1)
            #expect(await f.adapter.membershipSessionIDs(for: p2) == [s1])
            #expect(await f.adapter.connectionGenerations[s1] == 6)
            #expect(await f.adapter.hasSessionTicketForTesting(s1))
        }
        #expect(await f.adapter.membershipSessionIDs(for: player).isEmpty)
    }

    @Test("A disconnect issued during the registration waits for it, then removes the session")
    func disconnectWaitsForRegistration() async throws {
        let f = await RegisterSessionFixture()
        try await f.keeperJoin(s1, c1, as: player)
        let gate = TestGate()
        let holds = HoldRegistry<TransportAdapterHoldPoint>()
        holds.on(.registrationGeneration, arrival: 1) { await gate.arrive() }
        let queued = await f.queuedSignal(on: holds)
        let keeperHolds = HoldRegistry<LandKeeperHoldPoint>()
        await f.keeper.installHolds(keeperHolds.hook)

        let registration = Task { await f.register(s1, c1, as: player, generation: 7) }
        #expect(await gate.waitForArrivals(1))
        let disconnect = Task { await f.adapter.onDisconnect(sessionID: s1, clientID: c1) }
        // The second queued operation: the disconnect, behind the held registration.
        #expect(await queued.waitForArrivals(2))
        #expect(keeperHolds.arrivalCount(at: .leave) == 0)
        #expect(await f.adapter.membershipSessionIDs(for: player) == [s1])

        gate.open()
        await registration.value
        await disconnect.value
        #expect(keeperHolds.arrivalCount(at: .leave) == 1)
        #expect(await f.adapter.membershipSessionIDs(for: player).isEmpty)
        #expect(await f.adapter.connectionGenerations[s1] == nil)
        #expect(await f.keeper.playerCount() == 0)
    }
}

/// Records each close and each final frame with the connection generation it was for, as
/// "<session>@<generation or any>".
private actor GenerationRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var closes: [String] = []
    private(set) var queuedCloses: [String] = []
    private(set) var frames: [String] = []
    let closeSignal = TestGate()
    let queuedCloseSignal = TestGate()

    init() {
        closeSignal.open()
        queuedCloseSignal.open()
    }

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func sendSessionFrames(_ batch: [SessionFrame]) async {
        frames += batch.map { Self.label($0.sessionID, $0.connectionGeneration) }
    }
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        closes.append(Self.label(sessionID, generation))
        await closeSignal.arrive()
    }
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID, generation: UInt64?) async {
        queuedCloses.append(Self.label(sessionID, generation))
        await queuedCloseSignal.arrive()
    }
    nonisolated var supportsCloseSession: Bool { true }

    static func label(_ sessionID: SessionID, _ generation: UInt64?) -> String {
        "\(sessionID.rawValue)@\(generation.map(String.init) ?? "any")"
    }
}

@Suite("The adapter's delayed closes carry the connection they were decided for (#531)")
struct TransportAdapterGenerationCloseTests {
    let player = PlayerID("p1")
    let s1 = SessionID("s1"), c1 = ClientID("c1")
    let s2 = SessionID("s2"), c2 = ClientID("c2")
    let s3 = SessionID("s3"), c3 = ClientID("c3")

    private func makeAdapter() async -> (TransportAdapter<RegisterSessionTestState>, LandKeeper<RegisterSessionTestState>, GenerationRecordingTransport) {
        let definition = Land("generation-close", using: RegisterSessionTestState.self) { Rules {} }
        let transport = GenerationRecordingTransport()
        let keeper = LandKeeper(definition: definition, initialState: RegisterSessionTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<RegisterSessionTestState>(keeper: keeper, transport: transport, landID: "generation-close")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        return (adapter, keeper, transport)
    }

    private func keeperJoinAndRegister(
        _ adapter: TransportAdapter<RegisterSessionTestState>, _ keeper: LandKeeper<RegisterSessionTestState>,
        _ session: SessionID, _ client: ClientID, as player: PlayerID, generation: UInt64?, keeperJoin: Bool = true
    ) async throws {
        if keeperJoin {
            _ = try await keeper.join(
                session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
                clientID: client, sessionID: session, services: LandServices()
            )
        }
        await adapter.onConnect(sessionID: session, clientID: client)
        await adapter.registerSession(sessionID: session, clientID: client, playerID: player, authInfo: nil, connectionGeneration: generation)
    }

    @Test("A superseded session is closed for its own connection generation")
    func supersededCloseCarriesGeneration() async throws {
        let (adapter, keeper, transport) = await makeAdapter()
        try await keeperJoinAndRegister(adapter, keeper, s1, c1, as: player, generation: 5)
        try await keeperJoinAndRegister(adapter, keeper, s2, c2, as: player, generation: 6)
        #expect(await transport.closeSignal.waitForArrivals(1))
        #expect(await transport.closes == ["s1@5"])
    }

    @Test("A refused registration is closed for the registration's generation; without one, by ID")
    func refusedRegistrationCloseCarriesGeneration() async throws {
        let (adapter, keeper, transport) = await makeAdapter()
        try await keeperJoinAndRegister(adapter, keeper, s1, c1, as: player, generation: 5)
        try await keeperJoinAndRegister(adapter, keeper, s2, c2, as: player, generation: 9, keeperJoin: false)
        try await keeperJoinAndRegister(adapter, keeper, s3, c3, as: player, generation: nil, keeperJoin: false)
        #expect(await transport.closeSignal.waitForArrivals(2))
        #expect(await Set(transport.closes) == ["s2@9", "s3@any"])
        #expect(await adapter.staleRegistrationRefusals == 2)
    }

    @Test("A join ended before admission sends its final frame and closes for the router's connection")
    func joinEndedBeforeAdmissionCarriesGeneration() async throws {
        let (adapter, _, transport) = await makeAdapter()
        let withFrame = SessionID("timed-out-frame"), withoutFrame = SessionID("timed-out")
        #expect(await adapter.endJoinBeforeAdmission(
            withFrame, finalFrame: Data("error".utf8), attemptEnd: JoinAttemptEnd(), connectionGeneration: 4
        ))
        #expect(await adapter.endJoinBeforeAdmission(
            withoutFrame, finalFrame: nil, attemptEnd: JoinAttemptEnd(), connectionGeneration: 8
        ))
        // The writer sends the frame, then the queued close behind it.
        #expect(await transport.queuedCloseSignal.waitForArrivals(1))
        #expect(await transport.frames == ["timed-out-frame@4"])
        #expect(await transport.closeSignal.waitForArrivals(1))
        #expect(await transport.queuedCloses == ["timed-out-frame@4"])
        #expect(await transport.closes == ["timed-out@8"])
    }
}
