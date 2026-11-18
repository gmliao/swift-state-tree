// Tests/SwiftStateTreeTransportTests/HandshakeFrameLimitTests.swift
//
// The pre-handshake frame-size cap (`HandshakeFrameLimit`): before a session's join completes,
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

/// Records what the transport sends to one session, and how it was closed.
private actor LimitConnection: WebSocketConnection {
    private(set) var messages: [Data] = []
    private(set) var closes: [SessionClose] = []

    func send(_ data: Data) async throws { messages.append(data) }
    func close() async throws { closes.append(.normal) }
    func close(with close: SessionClose) async throws { closes.append(close) }

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

@Suite("Pre-handshake frame-size cap")
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

        #expect(await pollUntil { await fixture.router.getBoundLandID(for: session) != nil }, "the session joined")
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.isEmpty)
        let container = try #require(await fixture.manager.getLand(landID: fixture.landID))
        #expect(await pollUntil { await container.keeper.currentState().players[PlayerID("p1")] != nil })
    }

    @Test("One byte over the limit is refused before it is parsed: error, 1009 close, and no join reaches the land")
    func overLimitRefused() async throws {
        let limit = 512
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-over-limit")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: limit + 1))

        #expect(await pollUntil { await !connection.closes.isEmpty }, "the session is closed")
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

        #expect(await pollUntil { await !connection.closes.isEmpty })
        #expect(await connection.errorCodes == [ErrorCode.invalidMessageFormat.rawValue])
    }

    @Test("After the join, frames over the limit are decoded as before")
    func afterJoinUnlimited() async throws {
        let limit = 512
        let fixture = try LimitFixture(limit: limit)
        let session = SessionID("s-after-join")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: limit))
        #expect(await pollUntil { await fixture.router.getBoundLandID(for: session) != nil })

        let text = String(repeating: "y", count: 4 * limit)
        let action = try JSONEncoder().encode(TransportMessage.action(
            requestID: "a-1",
            action: ActionEnvelope(typeIdentifier: "HandshakeLimitNoteAction", payload: AnyCodable(["text": text]))
        ))
        #expect(action.count > limit)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: action)

        let container = try #require(await fixture.manager.getLand(landID: fixture.landID))
        #expect(await pollUntil { await container.keeper.currentState().notes == 1 }, "the action ran")
        #expect(await connection.closes.isEmpty)
        #expect(await connection.errorCodes.isEmpty)
    }

    @Test("With no limit (nil), a large frame before the join is decoded as before")
    func noLimit() async throws {
        let fixture = try LimitFixture(limit: nil)
        let session = SessionID("s-no-limit")
        let connection = await fixture.connect(session)
        await fixture.transport.handleIncomingMessage(sessionID: session, data: try join(bytes: 128 * 1024))

        #expect(await pollUntil { await fixture.router.getBoundLandID(for: session) != nil })
        #expect(await connection.closes.isEmpty)
    }
}
