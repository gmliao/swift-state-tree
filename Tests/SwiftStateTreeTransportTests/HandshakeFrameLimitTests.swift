// Tests/SwiftStateTreeTransportTests/HandshakeFrameLimitTests.swift
//
// The pre-handshake bounds (`HandshakeFrameLimit`): before a session's join is admitted, a frame
// over the size limit is refused before it is parsed, with an INVALID_MESSAGE_FORMAT error and a
// 1009 close, and the land never sees a join. A frame at the limit is decoded as before, and
// frames after the join aren't limited. Refused pre-join frames past the budget close the
// session with 1008, after the refused frame's own error.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct HandshakeLimitTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    @Sync(.broadcast)
    var notes: Int = 0
}

@Payload
struct HandshakeLimitNoteResponse: ResponsePayload {
    let length: Int
}

@Payload
struct HandshakeLimitNoteAction: ActionPayload {
    typealias Response = HandshakeLimitNoteResponse
    let text: String
}

/// Records what the transport sends to one session, and how it was closed, in order. Tests wait
/// on these events (`waitFor`), not on time: each send, send attempt and close resumes the waiters
/// whose condition holds. `holdSends` stops the session's drain inside `send` until
/// `releaseSends`; `failSends` makes every send throw, which ends the drain.
private actor LimitConnection: WebSocketConnection {
    enum Event: Equatable, Sendable {
        case sent(MessageKind?)
        case closed(SessionClose)
    }

    struct SendFailed: Error {}

    private(set) var messages: [Data] = []
    private(set) var closes: [SessionClose] = []
    private(set) var events: [Event] = []
    private(set) var sendAttempts = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var failing = false
    private var waiters: [UInt64: (condition: @Sendable (Snapshot) -> Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiter: UInt64 = 0

    struct Snapshot: Sendable {
        let kinds: [MessageKind]
        let closes: [SessionClose]
        let sendAttempts: Int
    }

    func holdSends() { holding = true }

    func releaseSends() {
        holding = false
        let resumed = held
        held = []
        for continuation in resumed { continuation.resume() }
    }

    func failSends() { failing = true }

    func send(_ data: Data) async throws {
        sendAttempts += 1
        resumeWaiters()
        if failing { throw SendFailed() }
        if holding { await withCheckedContinuation { held.append($0) } }
        messages.append(data)
        events.append(.sent(try? JSONDecoder().decode(TransportMessage.self, from: data).kind))
        resumeWaiters()
    }

    func close() async throws { record(.normal) }
    func close(with close: SessionClose) async throws { record(close) }

    private func record(_ close: SessionClose) {
        closes.append(close)
        events.append(.closed(close))
        resumeWaiters()
    }

    /// Returns once `condition` holds for what the connection has received, or once the task is
    /// cancelled: the suite's time limit cancels a test whose event never comes, and the
    /// expectations after the wait then fail.
    func waitFor(_ condition: @escaping @Sendable (Snapshot) -> Bool) async {
        if condition(snapshot) || Task.isCancelled { return }
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                waiters[id] = (condition, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    private var snapshot: Snapshot { Snapshot(kinds: kinds, closes: closes, sendAttempts: sendAttempts) }

    private func resumeWaiters() {
        let now = snapshot
        for (id, waiter) in waiters where waiter.condition(now) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    var errorCodes: [String] {
        messages.compactMap { data in
            guard let message = try? JSONDecoder().decode(TransportMessage.self, from: data),
                  case .error(let payload) = message.payload else { return nil }
            return payload.code
        }
    }

    var kinds: [MessageKind] {
        messages.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0).kind }
    }
}

private struct LimitFixture {
    let transport: WebSocketTransport
    let manager: LandManager<HandshakeLimitTestState>
    let router: LandRouter<HandshakeLimitTestState>
    let landID = LandID(landType: "handshake-limit", instanceId: "one")

    init(limit: Int?, refusedFrameBudget: Int? = nil) throws {
        let definition = Land("handshake-limit", using: HandshakeLimitTestState.self) {
            Rules {
                // Player "deny" is refused: a join the router refuses after its decode.
                CanJoin { (_: HandshakeLimitTestState, session: PlayerSession, _: LandContext) in
                    session.playerID == "deny" ? .deny(reason: "denied") : .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin { (state: inout HandshakeLimitTestState, ctx: LandContext) in
                    state.players[ctx.playerID] = "Joined"
                }
                HandleAction(HandshakeLimitNoteAction.self) { (state: inout HandshakeLimitTestState, action: HandshakeLimitNoteAction, _: LandContext) in
                    state.notes += 1
                    return HandshakeLimitNoteResponse(length: action.text.utf8.count)
                }
            }
        }
        transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in HandshakeLimitTestState() }
        )
        manager = LandManager<HandshakeLimitTestState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in HandshakeLimitTestState() },
            transport: transport
        )
        router = LandRouter<HandshakeLimitTestState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: .json,
            maxHandshakeFrameBytes: limit,
            maxRefusedHandshakeFrames: refusedFrameBudget
        )
    }

    /// Holds the router once at `point`; the test opens the gate.
    func hold(at point: LandRouterHoldPoint) async -> TestGate {
        let gate = TestGate()
        let registry = HoldRegistry<LandRouterHoldPoint>().on(point, arrival: 1) { await gate.arrive() }
        await router.installHolds(registry.hook)
        return gate
    }

    func connect(_ session: SessionID) async -> LimitConnection {
        await transport.setDelegate(router)
        let connection = LimitConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }
}

/// A JSON-object join of exactly `bytes` bytes: the metadata's `pad` string fills it up.
/// `playerID` "deny" makes a join the land refuses (CanJoin).
private func join(bytes: Int, requestID: String = "join-1", playerID: String = "p1") throws -> Data {
    func frame(_ pad: String) throws -> Data {
        var metadata = StateUpdateFeature.joinMetadata
        metadata["pad"] = AnyCodable(pad)
        return try JSONEncoder().encode(TransportMessage.join(
            requestID: requestID, landType: "handshake-limit", landInstanceId: "one",
            playerID: playerID, deviceID: nil, metadata: metadata
        ))
    }
    let base = try frame("").count
    precondition(bytes >= base, "a join is at least \(base) bytes")
    let data = try frame(String(repeating: "x", count: bytes - base))
    precondition(data.count == bytes)
    return data
}

@Suite("Pre-handshake frame-size cap", .timeLimit(.minutes(1)))
struct HandshakeFrameLimitTests {
    @Test("HANDSHAKE_FRAME_MAX_BYTES: unset, negative or not an integer gives 8 KiB; 0 turns it off")
    func environment() {
        let key = TransportEnvKeys.handshakeFrameMaxBytes
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [:]) == 8 * 1024)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "1000"]) == 1000)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "0"]) == nil)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "-5"]) == 8 * 1024)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "8k"]) == 8 * 1024)
    }

    @Test("HANDSHAKE_REFUSED_FRAME_BUDGET: unset, negative or not an integer gives 8; 0 turns it off")
    func budgetEnvironment() {
        let key = TransportEnvKeys.handshakeRefusedFrameBudget
        #expect(HandshakeFrameLimit.refusedFrameBudgetFromEnvironment(environment: [:]) == 8)
        #expect(HandshakeFrameLimit.refusedFrameBudgetFromEnvironment(environment: [key: "3"]) == 3)
        #expect(HandshakeFrameLimit.refusedFrameBudgetFromEnvironment(environment: [key: "0"]) == nil)
        #expect(HandshakeFrameLimit.refusedFrameBudgetFromEnvironment(environment: [key: "-1"]) == 8)
        #expect(HandshakeFrameLimit.refusedFrameBudgetFromEnvironment(environment: [key: "many"]) == 8)
    }

    @Test("A real join, every state-update feature declared and a metadata object, is far below the default")
    func realJoinFits() throws {
        var metadata = StateUpdateFeature.joinMetadata
        metadata["name"] = AnyCodable("Alice")
        metadata["level"] = AnyCodable(3)
        metadata["prefs"] = AnyCodable(["sound": false, "volume": 0.5] as [String: Any])
        let frame = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "hero-defense", landInstanceId: "room-01",
            playerID: "player-1", deviceID: "device-1", metadata: metadata
        ))
        print("[handshake-frame-limit] real join: \(frame.count) bytes")
        #expect(frame.count < 1024, "\(frame.count) bytes")
        #expect(frame.count * 16 < HandshakeFrameLimit.defaultMaxBytes)
    }

    @Test("A join of exactly the limit is decoded and joins")
    func atLimitJoins() async throws {
        let limit = 512
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-at-limit")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: limit))

        await connection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await fixture.router.getBoundLandID(for: session) != nil, "the session joined")
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.isEmpty)
        let container = try #require(await fixture.manager.getLand(landID: fixture.landID))
        // The join response follows OnJoin.
        #expect(await container.keeper.currentState().players[PlayerID("p1")] != nil)
    }

    @Test("One byte over the limit is refused before it is parsed: error, 1009 close, and no join reaches the land")
    func overLimitRefused() async throws {
        let limit = 512
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-over-limit")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: limit + 1))

        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.closes == [.handshakeFrameTooBig])
        #expect(SessionClose.handshakeFrameTooBig.code == 1009)
        #expect(await connection.errorCodes == [ErrorCode.invalidMessageFormat.rawValue])
        #expect(await fixture.router.getBoundLandID(for: session) == nil)
        #expect(await fixture.manager.getLand(landID: fixture.landID) == nil, "no land was looked up or created")
    }

    @Test("Over the limit, a frame that isn't JSON gets the size refusal, not a parse error: nothing parsed it")
    func overLimitIsNotParsed() async throws {
        let limit = 64
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-not-parsed")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: Data(repeating: 0x7B, count: limit + 1))

        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.errorCodes == [ErrorCode.invalidMessageFormat.rawValue])
    }

    @Test("After the join, frames over the limit are decoded as before")
    func afterJoinUnlimited() async throws {
        let limit = 512
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-after-join")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: limit))
        await connection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty, "the join at the limit was accepted")

        let text = String(repeating: "y", count: 4 * limit)
        let action = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-1",
            action: ActionEnvelope(typeIdentifier: "HandshakeLimitNoteAction", payload: AnyCodable(["text": text]))
        ))
        #expect(action.count > limit)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: action)

        let container = try #require(await fixture.manager.getLand(landID: fixture.landID))
        await connection.waitFor { $0.kinds.contains(.actionResponse) || !$0.closes.isEmpty }
        #expect(await container.keeper.currentState().notes == 1, "the action ran")
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.isEmpty)
    }

    @Test("With no limit (nil), a large frame before the join is decoded as before")
    func noLimit() async throws {
        let fixture = try LimitFixture(limit: nil)
        let session = SessionID("s-no-limit")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 128 * 1024))

        await connection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await fixture.router.getBoundLandID(for: session) != nil)
        #expect(await connection.closes.isEmpty)
    }

    @Test("The error reaches the connection before the 1009 close, and a join sent after the refusal is dropped")
    func errorBeforeCloseAndTerminal() async throws {
        let fixture = try LimitFixture(limit: 512)
        let session = SessionID("s-ordered")
        let connection = await fixture.connect(session)
        // The drain stops inside the first send: the error is held at the connection.
        await connection.holdSends()
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 513))
        await connection.waitFor { $0.sendAttempts >= 1 }
        // The router's handling of the frame has returned, and the close was requested: it waits
        // behind the held error. (`send` + `closeSession` would have closed by now.)
        #expect(await connection.closes.isEmpty, "no close while the error is held")

        // A valid join sent before the close goes out is dropped, not handled.
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400, requestID: "join-2"))
        #expect(await fixture.router.framesDroppedAfterRefusalForTesting == 1)

        await connection.releaseSends()
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.events == [.sent(.error), .closed(.handshakeFrameTooBig)])
        #expect(await fixture.router.getBoundLandID(for: session) == nil)
        #expect(await fixture.manager.getLand(landID: fixture.landID) == nil, "no land was looked up or created")
    }

    @Test("A session whose drain already ended (a failed send) is closed with 1009 at once, not at the bound")
    func drainAlreadyEnded() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("s-drain-ended")
        let connection = LimitConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: session))
        await connection.failSends()
        // A frame whose send fails ends the drain.
        await transport.sendSessionFrames([SessionFrame(data: Data([0x01]), sessionID: session, connectionGeneration: generation)])
        let drain = try #require(await transport.sendQueueDrainTaskForTesting(session))
        await drain.value
        // The close marker can't be read now (`.terminated`), and the bound is out of reach:
        // only the `.terminated` branch closes, at once.
        await transport.closeSessionAfterQueuedFrames(session, timeout: .seconds(3600), generation: generation, close: .handshakeFrameTooBig)
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.closes == [.handshakeFrameTooBig])
    }

    /// Connects `session` again after the delayed close `kind`, for the first connection, is
    /// held before its check; then lets it run and returns the second connection.
    private func reconnectUnderHeldClose(
        _ transport: WebSocketTransport, _ session: SessionID, first: LimitConnection,
        kind: WebSocketTransport.DelayedClose, start: () async -> Void
    ) async throws -> LimitConnection {
        let held = TestGate()
        let ran = TestGate()
        ran.open()
        await transport.setDelayedCloseForTesting { stage in
            switch stage {
            case .willCheck(kind): await held.arrive()
            case .didRun(kind): await ran.arrive()
            default: break
            }
        }
        await start()
        #expect(await held.waitForArrivals(1), "the delayed close ran")
        // The client goes, and a new connection takes the ID before the old close checks it.
        await transport.handleDisconnection(sessionID: session)
        let second = LimitConnection()
        await transport.handleConnection(sessionID: session, connection: second, authInfo: nil)
        held.open()
        #expect(await ran.waitForArrivals(1))
        #expect(await first.closes.isEmpty)
        return second
    }

    @Test("The drain's close marker for a connection that has gone leaves a new connection under the ID open")
    func staleMarkerClose() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("s-stale-marker")
        let first = LimitConnection()
        await transport.handleConnection(sessionID: session, connection: first, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: session))
        let second = try await reconnectUnderHeldClose(transport, session, first: first, kind: .marker) {
            // Nothing queued: the drain reads the marker at once. The bound is out of reach.
            await transport.closeSessionAfterQueuedFrames(session, timeout: .seconds(3600), generation: generation, close: .handshakeFrameTooBig)
        }
        #expect(await second.closes.isEmpty, "the old connection's marker closed the new one")
        #expect(await transport.connectionGeneration(for: session) != generation)
        #expect(await transport.connectionGeneration(for: session) != nil)
    }

    @Test("A close that ends at its marker isn't counted as a bound close; one whose drain is held past the bound is (#555)")
    func boundClosesAreCounted() async throws {
        let transport = WebSocketTransport()
        // The bound's close is held before its check, and noted once it ran.
        let boundHeld = TestGate()
        let boundRan = TestGate()
        boundRan.open()
        await transport.setDelayedCloseForTesting { stage in
            switch stage {
            case .willCheck(.bound): await boundHeld.arrive()
            case .didRun(.bound): await boundRan.arrive()
            default: break
            }
        }
        // At the marker: nothing queued, the drain reads it at once. The bound runs out at once
        // too, and is held until the marker closed the connection; then it runs, and loses.
        let atMarker = SessionID("s-at-marker")
        let first = LimitConnection()
        await transport.handleConnection(sessionID: atMarker, connection: first, authInfo: nil)
        await transport.closeSessionAfterQueuedFrames(atMarker, timeout: .zero, close: .handshakeFrameTooBig)
        await first.waitFor { !$0.closes.isEmpty }
        #expect(await boundHeld.waitForArrivals(1), "the losing bound fired")
        boundHeld.open()
        #expect(await boundRan.waitForArrivals(1), "the losing bound ran")
        #expect(await transport.finalFrameClosesAtBound == 0, "a bound that ran after the marker isn't counted")

        // At the bound: the drain is held on a frame, so the marker isn't read; the bound runs
        // out at once and closes the connection.
        let atBound = SessionID("s-at-bound")
        let second = LimitConnection()
        await transport.handleConnection(sessionID: atBound, connection: second, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: atBound))
        await second.holdSends()
        await transport.sendSessionFrames([SessionFrame(data: Data([0x01]), sessionID: atBound, connectionGeneration: generation)])
        await second.waitFor { $0.sendAttempts >= 1 }
        await transport.closeSessionAfterQueuedFrames(atBound, timeout: .zero, generation: generation, close: .handshakeFrameTooBig)
        await second.waitFor { !$0.closes.isEmpty }
        #expect(await boundRan.waitForArrivals(2))
        #expect(await transport.finalFrameClosesAtBound == 1)
        await second.releaseSends()
    }

    @Test("The bound's close for a connection that has gone leaves a new connection under the ID open")
    func staleBoundClose() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("s-stale-bound")
        let first = LimitConnection()
        await transport.handleConnection(sessionID: session, connection: first, authInfo: nil)
        let generation = try #require(await transport.connectionGeneration(for: session))
        await first.holdSends()
        let second = try await reconnectUnderHeldClose(transport, session, first: first, kind: .bound) {
            // The drain is held on a frame, so the marker isn't read; the bound runs out at once.
            await transport.sendSessionFrames([SessionFrame(data: Data([0x01]), sessionID: session, connectionGeneration: generation)])
            await first.waitFor { $0.sendAttempts >= 1 }
            await transport.closeSessionAfterQueuedFrames(session, timeout: .zero, generation: generation, close: .handshakeFrameTooBig)
        }
        await first.releaseSends()
        #expect(await second.closes.isEmpty, "the old connection's bound closed the new one")
        #expect(await transport.connectionGeneration(for: session) != nil)
    }

    /// Through the router: the refusal ends with the connection. The delayed closes' generation
    /// checks are covered at the transport (`staleMarkerClose`, `staleBoundClose`): here the
    /// disconnect cancels the drain, so the marker isn't read.
    @Test("A client that disconnects between the refusal and its close: the new connection under the ID joins and stays open")
    func disconnectBeforeMarker() async throws {
        let fixture = try LimitFixture(limit: 512)
        let session = SessionID("s-reconnect")
        let first = await fixture.connect(session)
        await first.holdSends()
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 513))
        await first.waitFor { $0.sendAttempts >= 1 }
        // The client goes before the drain reaches the close marker.
        await fixture.transport.handleDisconnection(sessionID: session)
        await first.releaseSends()
        #expect(await !first.closes.contains(.handshakeFrameTooBig), "the old connection's close isn't sent after it left")

        // The refusal ended with that connection: a new one under the same ID is read again.
        let second = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400))
        await second.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await second.closes.isEmpty)
        #expect(await fixture.router.getBoundLandID(for: session) != nil)
    }

    /// Only a join not yet in the keeper's join: one already in it (CanJoin, the admission) isn't
    /// cut, and finishes before the forwarded disconnect removes the player, as on a client
    /// disconnect at that point (#241).
    @Test("A join not yet in the keeper when the frame arrives is ended: it never reaches the land", arguments: [LandRouterHoldPoint.afterLand, .beforeAdmit])
    func joinInProgressEnded(point: LandRouterHoldPoint) async throws {
        let fixture = try LimitFixture(limit: 512)
        let session = SessionID("s-in-progress")
        let connection = await fixture.connect(session)
        let gate = await fixture.hold(at: point)
        let joinFrame = try join(bytes: 400)
        let transport = fixture.transport
        let joining = Task { await transport.handleIncomingMessage(sessionID: session, data: joinFrame) }
        #expect(await gate.waitForArrivals(1))

        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 513, requestID: "join-2"))
        gate.open()
        await joining.value
        await connection.waitFor { !$0.closes.isEmpty }

        #expect(await connection.closes == [.handshakeFrameTooBig])
        #expect(await !connection.kinds.contains(.joinResponse))
        #expect(await fixture.router.getBoundLandID(for: session) == nil)
        if let container = await fixture.manager.getLand(landID: fixture.landID) {
            // Found or created before the hold: the land exists, but the player never joined it.
            #expect(await container.keeper.currentState().players.isEmpty)
        }
    }

    @Test("At the default limit a join is decoded and joins; one byte over it is refused with 1009")
    func defaultLimit() async throws {
        let limit = HandshakeFrameLimit.defaultMaxBytes
        let fixture = try LimitFixture(limit: limit)
        let at = SessionID("s-default-at")
        let atConnection = await fixture.connect(at)
        await fixture.transport.handleIncomingMessage(sessionID: at, data: try join(bytes: limit))
        await atConnection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await atConnection.closes.isEmpty)
        #expect(await fixture.router.getBoundLandID(for: at) != nil)

        let over = SessionID("s-default-over")
        let overConnection = await fixture.connect(over)
        await fixture.transport.handleIncomingMessage(sessionID: over, data: try join(bytes: limit + 1, requestID: "join-2"))
        await overConnection.waitFor { !$0.closes.isEmpty }
        #expect(await overConnection.closes == [.handshakeFrameTooBig])
        #expect(await fixture.router.getBoundLandID(for: over) == nil)
    }

    @Test("The budget's boundary: 8 refused frames get their errors, the 9th its error and then a 1008 close")
    func budgetBoundary() async throws {
        let budget = HandshakeFrameLimit.defaultMaxRefusedFrames
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: budget)
        let session = SessionID("s-budget")
        let connection = await fixture.connect(session)
        // A frame that isn't JSON: refused at its first byte.
        let notJSON = Data([0x01])
        for _ in 0..<budget {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: notJSON)
        }
        await connection.waitFor { $0.kinds.count >= budget || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty, "within the budget the session stays open")
        #expect(await connection.errorCodes.count == budget)

        await fixture.transport.handleIncomingMessage(sessionID: session, data: notJSON)
        await connection.waitFor { !$0.closes.isEmpty }
        let events = await connection.events
        #expect(events == Array(repeating: .sent(.error), count: budget + 1) + [.closed(.handshakeRefusedFrames)])
        #expect(SessionClose.handshakeRefusedFrames.code == 1008)
        // Closed: a join it sends next doesn't join.
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400))
        #expect(await fixture.router.getBoundLandID(for: session) == nil)
    }

    @Test("Malformed frames, non-join messages and refused joins all count against one budget")
    func budgetMixesRefusals() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 4)
        let session = SessionID("s-budget-mix")
        let connection = await fixture.connect(session)
        let action = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-1",
            action: ActionEnvelope(typeIdentifier: "HandshakeLimitNoteAction", payload: AnyCodable(["text": "x"]))
        ))
        let refused: [Data] = [
            Data(),                                                          // empty
            Data([0x01, 0x02]),                                              // not JSON
            Data("{\"kind\":".utf8),                                         // undecodable JSON
            try join(bytes: 400, requestID: "join-x", playerID: "deny"),  // a refused join
        ]
        for frame in refused {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: frame)
        }
        await connection.waitFor { $0.kinds.count >= refused.count || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.count == refused.count)

        // A message other than a join, before join: the fifth refusal.
        await fixture.transport.handleIncomingMessage(sessionID: session, data: action)
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.closes == [.handshakeRefusedFrames])
        #expect(await connection.errorCodes.count == refused.count + 1)
    }

    @Test("A valid join nested one past the client-frame limit is refused before it is parsed, and counts against the budget (#362)")
    func tooDeepCountsAgainstBudget() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 2)
        let session = SessionID("s-budget-deep")
        let connection = await fixture.connect(session)
        // A valid join, one level past the limit: its metadata holds nested objects. Without the
        // check it would be admitted, so the refusals below are the depth's.
        let limit = PayloadNesting.clientFrameMaxDepth
        func deepJoin(_ inner: Int) throws -> Data {
            var value: Any = [String: Any]()
            for _ in 0..<inner { value = ["a": value] }
            var metadata = StateUpdateFeature.joinMetadata
            metadata["deep"] = AnyCodable(value)
            return try JSONEncoder().encode(TransportMessage.join(
                requestID: "join-deep", landType: "handshake-limit", landInstanceId: "one",
                playerID: "p1", deviceID: nil, metadata: metadata
            ))
        }
        // The frame, its payload, the join and its metadata hold the value: 4 levels.
        let deep = try deepJoin(limit + 1 - 5)
        try PayloadNesting.checkJSON(deep, limit: limit + 1)
        #expect(throws: PayloadNesting.TooDeep.self) { try PayloadNesting.checkJSON(deep, limit: limit) }
        #expect(deep.count <= 512)
        for _ in 0..<2 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: deep)
        }
        await connection.waitFor { $0.kinds.count >= 2 || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes == Array(repeating: ErrorCode.invalidJSON.rawValue, count: 2))

        await fixture.transport.handleIncomingMessage(sessionID: session, data: deep)
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.closes == [.handshakeRefusedFrames])
        #expect(await connection.errorCodes.count == 3)
    }

    @Test("Views joining over one connection get JOIN_IN_PROGRESS without reaching the budget; the first join completes")
    func joinInProgressWithinBudget() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: HandshakeFrameLimit.defaultMaxRefusedFrames)
        let session = SessionID("s-views")
        let connection = await fixture.connect(session)
        let gate = await fixture.hold(at: .afterLand)
        let first = try join(bytes: 400)
        let transport = fixture.transport
        let joining = Task { await transport.handleIncomingMessage(sessionID: session, data: first) }
        #expect(await gate.waitForArrivals(1))

        // Three more views send their joins while the first is in progress.
        for view in 2...4 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400, requestID: "join-\(view)"))
        }
        await connection.waitFor { $0.kinds.count >= 3 || !$0.closes.isEmpty }
        #expect(await connection.errorCodes == Array(repeating: ErrorCode.joinInProgress.rawValue, count: 3))
        gate.open()
        await joining.value
        await connection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty)
        #expect(await fixture.router.getBoundLandID(for: session) != nil)
    }

    @Test("A join after a few refusals succeeds and stays open; refusals after the join don't count")
    func joinAfterRefusals() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 3)
        let session = SessionID("s-retry")
        let connection = await fixture.connect(session)
        for attempt in 0..<3 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400, requestID: "retry-\(attempt)", playerID: "deny"))
        }
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400))
        await connection.waitFor { $0.kinds.contains(.joinResponse) || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty)
        #expect(await fixture.router.getBoundLandID(for: session) != nil)

        // Joined: a second join is refused (`JOIN_ALREADY_JOINED`) but isn't a pre-join frame.
        for attempt in 0..<5 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400, requestID: "again-\(attempt)"))
        }
        await connection.waitFor { $0.kinds.filter { $0 == .error }.count >= 8 || !$0.closes.isEmpty }
        let codes = await connection.errorCodes
        #expect(await connection.closes.isEmpty, "\(codes)")
        #expect(codes.suffix(5) == Array(repeating: ErrorCode.joinAlreadyJoined.rawValue, count: 5), "\(codes)")
    }

    @Test("A session connected again under the same ID starts with a fresh budget")
    func reconnectGetsFreshBudget() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 3)
        let session = SessionID("s-reconnect")
        let first = await fixture.connect(session)
        for _ in 0..<3 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        }
        await first.waitFor { $0.kinds.count >= 3 || !$0.closes.isEmpty }
        #expect(await first.closes.isEmpty, "the budget isn't spent yet")
        await fixture.transport.handleDisconnection(sessionID: session)

        // The same ID, a new connection: a whole budget of refused frames gets only their errors.
        // (An over-budget refusal sends its error too, but drops the session first.)
        let second = await fixture.connect(session)
        for _ in 0..<3 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        }
        await second.waitFor { $0.kinds.count >= 3 || !$0.closes.isEmpty }
        #expect(await fixture.router.hasHandshakePhase(session), "the new connection isn't refused")
        #expect(await second.closes.isEmpty)
        #expect(await second.errorCodes == Array(repeating: ErrorCode.invalidJSON.rawValue, count: 3))
    }

    @Test("While the over-budget error is held, the session is already refused: a join and an oversized frame are dropped, then one 1008 close")
    func overBudgetTerminalWhileErrorHeld() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 2)
        let session = SessionID("s-held-ninth")
        let connection = await fixture.connect(session)
        for _ in 0..<2 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        }
        await connection.waitFor { $0.kinds.count >= 2 || !$0.closes.isEmpty }
        #expect(await fixture.router.hasHandshakePhase(session), "within the budget the session awaits its join")
        // The drain stops inside the over-budget error's send.
        await connection.holdSends()
        await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        await connection.waitFor { $0.sendAttempts >= 3 }
        #expect(await connection.closes.isEmpty, "no close while the error is held")
        #expect(await fixture.router.hasHandshakePhase(session) == false, "the session is refused before its error goes out")

        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400, requestID: "join-late"))
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 513, requestID: "join-big"))
        #expect(await fixture.router.framesDroppedAfterRefusalForTesting == 2)

        await connection.releaseSends()
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.events == [.sent(.error), .sent(.error), .sent(.error), .closed(.handshakeRefusedFrames)])
        #expect(await fixture.router.getBoundLandID(for: session) == nil)
        #expect(await fixture.manager.getLand(landID: fixture.landID) == nil, "no land was looked up or created")
    }

    @Test("A join refused because the land is shutting down (the server's doing) doesn't count against the budget")
    func serverCausedRefusalNotCounted() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: 1)
        // Creations stopped: the join's land creation throws `landShuttingDown`.
        await fixture.manager.stopCreations()
        let session = SessionID("s-shutting-down")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 400))
        await connection.waitFor { $0.kinds.count >= 2 || !$0.closes.isEmpty }
        let codes = await connection.errorCodes
        #expect(codes == [ErrorCode.invalidJSON.rawValue, ErrorCode.joinDenied.rawValue])
        #expect(await fixture.router.hasHandshakePhase(session), "told to retry, not refused: \(codes)")
        #expect(await connection.closes.isEmpty)
    }

    @Test("With no budget (nil), refused pre-join frames never close the session")
    func noBudget() async throws {
        let fixture = try LimitFixture(limit: 512, refusedFrameBudget: nil)
        let session = SessionID("s-no-budget")
        let connection = await fixture.connect(session)
        for _ in 0..<20 {
            await fixture.transport.handleIncomingMessage(sessionID: session, data: Data())
        }
        await connection.waitFor { $0.kinds.count >= 20 || !$0.closes.isEmpty }
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.count == 20)
    }
}
