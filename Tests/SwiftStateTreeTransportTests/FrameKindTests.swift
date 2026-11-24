// Tests/SwiftStateTreeTransportTests/FrameKindTests.swift
//
// #813: a frame's WebSocket type follows the bytes it carries, per frame, not per connection.
// The JoinResponse is always JSON (text); state updates take their encoder's kind and messages
// theirs, so a hybrid configuration sends text and binary frames on one connection.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct FrameKindTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Payload
struct FrameKindTestEvent: ServerEventPayload {
    let n: Int
}

@Payload
struct FrameKindTestReply: ResponsePayload {
    let n: Int
}

@Payload
struct FrameKindTestAction: ActionPayload {
    typealias Response = FrameKindTestReply
    let n: Int
}

/// The encodings a land can run with, a hybrid included.
enum FrameKindEncoding: String, CaseIterable, Sendable, CustomStringConvertible {
    case json
    case opcodeJsonArray
    case messagepack
    /// JSON messages with MessagePack state updates (`TransportAdapter.sendEvent`).
    case hybrid

    var description: String { rawValue }

    var config: TransportEncodingConfig {
        switch self {
        case .json: return TransportEncodingConfig(message: .json, stateUpdate: .jsonObject)
        case .opcodeJsonArray: return TransportEncodingConfig(message: .opcodeJsonArray, stateUpdate: .opcodeJsonArray)
        case .messagepack: return TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
        case .hybrid: return TransportEncodingConfig(message: .json, stateUpdate: .opcodeMessagePack)
        }
    }
}

/// Whether `data` is a JSON document: the test's oracle for a text frame's bytes. Every frame the
/// server writes is either JSON (an object or an array) or a MessagePack array.
private func isJSON(_ data: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
}

@Suite("A frame's WebSocket type follows the bytes it carries (#813)", .timeLimit(.minutes(1)))
struct FrameKindTests {
    @Test("Each encoding's kind: JSON is text, MessagePack is binary")
    func encodingKinds() {
        #expect(TransportEncoding.json.frameKind == .text)
        #expect(TransportEncoding.opcodeJsonArray.frameKind == .text)
        #expect(TransportEncoding.messagepack.frameKind == .binary)
        #expect(StateUpdateEncoding.jsonObject.frameKind == .text)
        #expect(StateUpdateEncoding.opcodeJsonArray.frameKind == .text)
        #expect(StateUpdateEncoding.opcodeJsonArrayLegacy.frameKind == .text)
        #expect(StateUpdateEncoding.opcodeMessagePack.frameKind == .binary)
    }

    @Test("The transport hands each session frame to the connection with its kind; send(_:to:) sends binary")
    func transportCarriesTheKind() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("kind-s1")
        let connection = RecordingConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        await transport.sendSessionFrames([
            SessionFrame(data: Data("{}".utf8), sessionID: session, connectionGeneration: nil, kind: .text),
            SessionFrame(data: Data([0x90]), sessionID: session, connectionGeneration: nil, kind: .binary),
        ])
        await transport.send(Data([0x91, 0x01]), to: .session(session))
        #expect(await connection.waitUntilRawFrames { $0.count == 3 })
        #expect(await connection.kinds == [.text, .binary, .binary])
    }

    @Test("The JoinResponse, the firstSync and a held server event each go out in the frame type of their bytes",
          arguments: FrameKindEncoding.allCases)
    func joinFramesFollowTheirBytes(encoding: FrameKindEncoding) async throws {
        let definition = Land("frame-kind", using: FrameKindTestState.self) {
            ServerEvents { Register(FrameKindTestEvent.self) }
            Rules {
                OnJoin { (state: inout FrameKindTestState, ctx: LandContext) in
                    state.players[ctx.playerID] = "Joined"
                    ctx.emitEvent(FrameKindTestEvent(n: 1), to: .session(ctx.sessionID))
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in FrameKindTestState() }
        )
        let manager = LandManager<FrameKindTestState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in FrameKindTestState() },
            transport: transport,
            transportEncoding: encoding.config
        )
        let router = LandRouter<FrameKindTestState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: encoding.config
        )
        await transport.setDelegate(router)

        let session = SessionID("kind-join")
        let connection = RecordingConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1",
            landType: "frame-kind",
            landInstanceId: "one",
            playerID: "p1",
            deviceID: nil,
            metadata: nil
        ))
        await transport.handleIncomingMessage(sessionID: session, data: join, kind: .text)
        #expect(await withinHangBound { await router.waitForNoPendingFlipForTesting() }, "\(encoding): the join's flip never ended")
        #expect(await connection.waitUntilRawFrames { $0.count >= 3 }, "\(encoding): the JoinResponse, the firstSync and the event")

        let frames = await connection.frames
        let kinds = await connection.kinds
        let config = encoding.config
        #expect(Array(kinds.prefix(3)) == [.text, config.stateUpdate.frameKind, config.message.frameKind],
                "\(encoding): JoinResponse, firstSync, event: \(kinds)")
        for (data, kind) in zip(frames, kinds) {
            #expect(isJSON(data) == (kind == .text), "\(encoding): a \(kind) frame's bytes: \(data.prefix(16).map { String(format: "%02x", $0) })")
        }
        if encoding == .hybrid {
            #expect(Set(kinds) == [.text, .binary], "hybrid: one connection carries both types")
        }
    }

    @Test("A router error before the join, an action response after it, and the opcode 107 frame each go out in the frame type of their bytes",
          arguments: FrameKindEncoding.allCases)
    func routerErrorsResponsesAndMergedFrames(encoding: FrameKindEncoding) async throws {
        let definition = Land("frame-kind-action", using: FrameKindTestState.self) {
            ServerEvents { Register(FrameKindTestEvent.self) }
            Rules {
                HandleAction(FrameKindTestAction.self) {
                    (state: inout FrameKindTestState, action: FrameKindTestAction, ctx: LandContext) in
                    state.players[ctx.playerID] = "n\(action.n)"
                    ctx.requestSyncNow()
                    return FrameKindTestReply(n: action.n)
                }
            }
        }
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in FrameKindTestState() }
        )
        let manager = LandManager<FrameKindTestState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in FrameKindTestState() },
            transport: transport,
            transportEncoding: encoding.config
        )
        let router = LandRouter<FrameKindTestState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: encoding.config
        )
        await transport.setDelegate(router)
        let session = SessionID("kind-action")
        let connection = RecordingConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)

        // Before the join: a frame the router can't read gets a JSON error.
        await transport.handleIncomingMessage(sessionID: session, data: Data("not a message".utf8), kind: .text)
        #expect(await connection.waitUntilRawFrames { !$0.isEmpty }, "\(encoding): the router's error")
        #expect(await connection.kinds.first == .text, "\(encoding): the error before the join is JSON")

        let join = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1", landType: "frame-kind-action", landInstanceId: "one",
            playerID: "p1", deviceID: nil, metadata: nil
        ))
        await transport.handleIncomingMessage(sessionID: session, data: join, kind: .text)
        #expect(await withinHangBound { await router.waitForNoPendingFlipForTesting() }, "\(encoding): the join's flip never ended")

        // After the join: an action in the land's message encoding; its response and the sync it
        // requests.
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: FrameKindTestAction.self),
            payload: AnyCodable(FrameKindTestAction(n: 7))
        )
        let action = try encoding.config.makeCodec().encode(TransportMessage.action(requestID: "act-1", action: envelope))
        await transport.handleIncomingMessage(sessionID: session, data: action, kind: encoding.config.message.frameKind)
        let requestID = Data("act-1".utf8)
        #expect(await connection.waitUntilRawFrames { $0.contains { $0.range(of: requestID) != nil } }, "\(encoding): the action's response")
        // Opcode 107: a MessagePack array of three whose first element is 107.
        let mergedPrefix: [UInt8] = [0x93, 0x6B]
        let merges = encoding.config.stateUpdate == .opcodeMessagePack
        if merges {
            #expect(await connection.waitUntilRawFrames { $0.contains { Array($0.prefix(2)) == mergedPrefix } }, "\(encoding): the opcode 107 frame")
        }

        let frames = await connection.frames
        let kinds = await connection.kinds
        for (data, kind) in zip(frames, kinds) {
            #expect(isJSON(data) == (kind == .text), "\(encoding): a \(kind) frame's bytes: \(data.prefix(16).map { String(format: "%02x", $0) })")
        }
        let responseKind = zip(frames, kinds).first { $0.0.range(of: requestID) != nil }?.1
        #expect(responseKind == encoding.config.message.frameKind, "\(encoding): the action response")
        if merges {
            let mergedKinds = zip(frames, kinds).filter { Array($0.0.prefix(2)) == mergedPrefix }.map(\.1)
            #expect(!mergedKinds.isEmpty && mergedKinds.allSatisfy { $0 == .binary }, "\(encoding): opcode 107 frames are binary")
        }
    }
}
