// Tests/SwiftStateTreeTransportTests/HandshakeFrameLimitTests.swift
//
// The pre-handshake frame-size cap (`HandshakeFrameLimit`): before a session's join is admitted,
// a frame over the limit is refused before it is parsed, with an INVALID_MESSAGE_FORMAT error
// and a 1009 close, and the land never sees a join. A frame at the limit is decoded as before,
// and frames after the join aren't limited.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

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

    init(limit: Int?) throws {
        let definition = Land("handshake-limit", using: HandshakeLimitTestState.self) {
            Rules {
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
            maxHandshakeFrameBytes: limit
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
private func join(bytes: Int, requestID: String = "join-1") throws -> Data {
    func frame(_ pad: String) throws -> Data {
        var metadata = StateUpdateFeature.joinMetadata
        metadata["pad"] = AnyCodable(pad)
        return try JSONEncoder().encode(TransportMessage.join(
            requestID: requestID, landType: "handshake-limit", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: metadata
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
    @Test("HANDSHAKE_FRAME_MAX_BYTES: unset, negative or not an integer gives 64 KiB; 0 turns it off")
    func environment() {
        let key = TransportEnvKeys.handshakeFrameMaxBytes
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [:]) == 64 * 1024)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "1000"]) == 1000)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "0"]) == nil)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "-5"]) == 64 * 1024)
        #expect(HandshakeFrameLimit.fromEnvironment(environment: [key: "64k"]) == 64 * 1024)
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
        #expect(frame.count * 64 < HandshakeFrameLimit.defaultMaxBytes)
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

    @Test("A session whose drain already ended (a failed send) is still closed with 1009")
    func drainAlreadyEnded() async throws {
        let fixture = try LimitFixture(limit: 512)
        let session = SessionID("s-drain-ended")
        let connection = await fixture.connect(session)
        await connection.failSends()
        // A non-JSON frame gets an error; its send fails and ends the drain.
        await fixture.transport.handleIncomingMessage(sessionID: session, data: Data([0x01]))
        let drain = try #require(await fixture.transport.sendQueueDrainTaskForTesting(session))
        await drain.value
        // The close marker can't be read now (`.terminated`): the close goes out at once.
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 513))
        await connection.waitFor { !$0.closes.isEmpty }
        #expect(await connection.closes == [.handshakeFrameTooBig])
        #expect(await fixture.manager.getLand(landID: fixture.landID) == nil)
    }

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

    @Test("A join in progress when the frame arrives is ended: it never reaches the land", arguments: [LandRouterHoldPoint.afterLand, .beforeAdmit])
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
}
