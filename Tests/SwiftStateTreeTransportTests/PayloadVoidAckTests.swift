// Tests/SwiftStateTreeTransportTests/PayloadVoidAckTests.swift
//
// The empty action response, `.completed(AnyCodable(()))`, which the keeper sends as the
// immediate ACK of an action queued for a tick (#541). With payload compression on, both array
// message encodings write it as an empty array; without it, the payload is `null`. Before #541
// the opcode JSON encoder had no `Void` branch and its `fatalError` ended the process.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct VoidAckTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0
}

@Payload
struct VoidAckTestResponse: ResponsePayload {
    let total: Int
}

@Payload
struct VoidAckTestAction: ActionPayload {
    typealias Response = VoidAckTestResponse
    let amount: Int
}

/// Records frames in send order.
private actor VoidAckTestTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }
}

@Suite("Payload: the empty (Void) action response per message encoding (#541)", .timeLimit(.minutes(1)))
struct PayloadVoidAckTests {
    private static let ack = TransportMessage.actionResponse(requestID: "r1", response: AnyCodable(()))

    @Test("compressed opcode JSON writes the Void response as an empty array, and it decodes back as one")
    func opcodeJSONCompressedRoundTrip() throws {
        let data = try OpcodeTransportMessageEncoder(enablePayloadCompression: true).encode(Self.ack)
        #expect(String(decoding: data, as: UTF8.self) == #"[102,"r1",[]]"#)

        let decoded = try OpcodeTransportMessageDecoder().decode(from: data)
        guard case .actionResponse(let payload) = decoded.payload else {
            Issue.record("decoded as \(decoded.kind), not an action response")
            return
        }
        #expect(payload.requestID == "r1")
        let response = try #require(payload.response.base as? [Any])
        #expect(response.isEmpty)
    }

    @Test("compressed MessagePack writes the same empty array")
    func messagePackCompressed() throws {
        let data = try MessagePackTransportMessageEncoder(enablePayloadCompression: true).encode(Self.ack)
        #expect(try unpack(data) == .array([.int(102), .string("r1"), .array([])]))
    }

    @Test("uncompressed opcode JSON writes the Void response as null")
    func opcodeJSONUncompressed() throws {
        let data = try OpcodeTransportMessageEncoder(enablePayloadCompression: false).encode(Self.ack)
        #expect(String(decoding: data, as: UTF8.self) == #"[102,"r1",null]"#)
    }

    @Test("an action queued on a tick land under the opcode config gets the empty-array ACK, and the land keeps answering")
    func queuedActionAckOnOpcodeConfig() async throws {
        let definition = Land("void-ack", using: VoidAckTestState.self) {
            Rules {
                HandleAction(VoidAckTestAction.self) {
                    (state: inout VoidAckTestState, action: VoidAckTestAction, _: LandContext) in
                    state.total += action.amount
                    return VoidAckTestResponse(total: state.total)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout VoidAckTestState, _: LandContext) in }
            }
        }
        let transport = VoidAckTestTransport()
        let keeper = LandKeeper(definition: definition, initialState: VoidAckTestState(), autoStartLoops: false)
        let adapter = TransportAdapter<VoidAckTestState>(
            keeper: keeper,
            transport: transport,
            landID: "void-ack",
            encodingConfig: .opcode,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)

        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        let joined = try #require(try await adapter.performJoin(
            playerSession: PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil
        ))
        await adapter.syncStateForNewPlayer(playerID: joined.playerID, sessionID: session)

        // As the TypeScript SDK sends it: an opcode array whose payload is an object.
        let client1 = OpcodeTransportMessageEncoder(enablePayloadCompression: false)
        for requestID in ["a1", "a2"] {
            let envelope = ActionEnvelope(
                typeIdentifier: "VoidAckTestAction",
                payload: AnyCodable(VoidAckTestAction(amount: 1))
            )
            await adapter.onMessage(try client1.encode(.action(requestID: requestID, action: envelope)), from: session)
        }
        _ = await adapter.waitForOutboundDrain()

        let responses = await transport.frames.compactMap { frame -> String? in
            guard case .session(let s) = frame.target, s == session else { return nil }
            let text = String(decoding: frame.data, as: UTF8.self)
            return text.hasPrefix("[102,") ? text : nil
        }
        #expect(responses == [#"[102,"a1",[]]"#, #"[102,"a2",[]]"#])
    }
}
