// Tests/SwiftStateTreeTransportTests/BoundedPayloadDecodeTests.swift
//
// A live input's payload is checked for depth once, by its frame's decode (#362). The adapter's
// decode pipeline bounds the whole frame at `PayloadNesting.clientFrameMaxDepth` and hands the
// keeper the proof (`DepthBounded`), so the payload decode doesn't walk the payload again. A
// payload without the proof (the keeper's public API called directly, a recorded input replayed)
// is walked.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct BoundedDecodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var hits: [String] = []
}

@Payload
struct BoundedDeepAction: ActionPayload {
    typealias Response = BoundedDeepResponse
    let tag: String
    let deep: AnyCodable
}

@Payload
struct BoundedDeepResponse: ResponsePayload {
    let count: Int
}

@Payload
struct BoundedDeepEvent: ClientEventPayload {
    let tag: String
    let deep: AnyCodable
}

/// Records every frame sent, so a test can see an action's response.
private actor BoundedFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append(message) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, _) in updates { frames.append(data) }
    }
}

private struct BoundedFixture {
    let keeper: LandKeeper<BoundedDecodeState>
    let adapter: TransportAdapter<BoundedDecodeState>
    let session = SessionID("s-bounded")
    let encoding: TransportEncodingConfig

    /// An action frame in the adapter's encoding, its `deep` value as given.
    func actionFrame(_ tag: String, deep: Any) throws -> Data {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BoundedDeepAction.self),
            payload: AnyCodable(["tag": tag, "deep": deep] as [String: Any])
        )
        return try encoding.makeCodec().encode(TransportMessage.action(requestID: "a-\(tag)", action: envelope))
    }

    /// A client-event frame in the adapter's encoding, its `deep` value as given.
    func eventFrame(_ tag: String, deep: Any) throws -> Data {
        let event = AnyClientEvent(
            type: payloadEventName(for: BoundedDeepEvent.self),
            payload: AnyCodable(["tag": tag, "deep": deep] as [String: Any])
        )
        return try encoding.makeCodec().encode(TransportMessage.event(event: .fromClient(event: event)))
    }
}

/// A tickless land: an action is applied before the adapter's `onMessage` returns, and so is a
/// client event sent before it.
private func makeBoundedFixture(encoding: TransportEncodingConfig) async throws -> BoundedFixture {
    let definition = Land("bounded-decode", using: BoundedDecodeState.self) {
        ClientEvents { Register(BoundedDeepEvent.self) }
        Rules {
            HandleAction(BoundedDeepAction.self) { (state: inout BoundedDecodeState, action: BoundedDeepAction, _: LandContext) in
                state.hits.append("action:\(action.tag)")
                return BoundedDeepResponse(count: state.hits.count)
            }
            HandleEvent(BoundedDeepEvent.self) { (state: inout BoundedDecodeState, event: BoundedDeepEvent, _: LandContext) in
                state.hits.append("event:\(event.tag)")
            }
        }
    }
    let sent = BoundedFrames()
    let keeper = LandKeeper(definition: definition, initialState: BoundedDecodeState())
    let adapter = TransportAdapter<BoundedDecodeState>(
        keeper: keeper,
        transport: sent,
        landID: "bounded-decode",
        encodingConfig: encoding
    )
    await sent.setDelegate(adapter)
    await keeper.setTransport(adapter)
    let fixture = BoundedFixture(keeper: keeper, adapter: adapter, encoding: encoding)
    let client = ClientID("c-bounded")
    await adapter.onConnect(sessionID: fixture.session, clientID: client)
    _ = try await adapter.performJoin(
        playerSession: PlayerSession(playerID: "p-bounded", deviceID: "dev", metadata: [:]),
        clientID: client,
        sessionID: fixture.session,
        authInfo: nil,
        joinResponse: { _, _ in Data("{}".utf8) }
    )
    return fixture
}

/// `[[...[]...]]`: `levels` arrays.
private func nestedArrays(_ levels: Int) -> Any {
    var value: Any = [Any]()
    for _ in 1..<max(1, levels) { value = [value] }
    return value
}

@Suite("A live input's payload is checked once, by its frame's decode (#362)", .timeLimit(.minutes(1)))
struct BoundedPayloadDecodeTests {
    static let encodings: [TransportEncodingConfig] = [.json, .opcode, .messagepack]

    @Test("A payload from a frame at the client limit decodes with its frame's bound, not walked again", arguments: encodings)
    func liveInputsComeBounded(encoding: TransportEncodingConfig) async throws {
        let fixture = try await makeBoundedFixture(encoding: encoding)
        // The deepest frame the client limit takes: the frame's own levels around `deep`, plus
        // `deep`'s arrays, total exactly the limit.
        let limit = PayloadNesting.clientFrameMaxDepth
        let probe = try fixture.actionFrame("probe", deep: [Any]())
        let around = try Self.depth(of: probe, encoding: encoding) - 1
        let deep = nestedArrays(limit - around)
        let action = try fixture.actionFrame("deep", deep: deep)
        #expect(try Self.depth(of: action, encoding: encoding) == limit)
        let event = try fixture.eventFrame("deep", deep: nestedArrays(2))

        await fixture.adapter.onMessage(event, from: fixture.session)
        await fixture.adapter.onMessage(action, from: fixture.session)

        #expect(await fixture.keeper.currentState().hits == ["event:deep", "action:deep"])
        // Every live decode came with the proof: the action twice (at intake and when applied),
        // the event once. If the adapter stopped handing the keeper the bounded form, the walk
        // would come back and `walked` would count it.
        let decodes = await fixture.keeper.livePayloadDecodesForTesting()
        #expect(decodes.walked == 0, "\(decodes)")
        #expect(decodes.bounded == 3, "\(decodes)")
    }

    @Test("A payload handed to the keeper's public API, without its frame, is walked")
    func directCallsAreWalked() async throws {
        let fixture = try await makeBoundedFixture(encoding: .json)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BoundedDeepAction.self),
            payload: AnyCodable(["tag": "direct", "deep": [Any]()] as [String: Any])
        )
        _ = try await fixture.keeper.handleActionEnvelope(
            envelope,
            playerID: PlayerID("p-bounded"),
            clientID: ClientID("c-bounded"),
            sessionID: fixture.session
        )
        #expect(await fixture.keeper.currentState().hits == ["action:direct"])
        let decodes = await fixture.keeper.livePayloadDecodesForTesting()
        #expect(decodes.bounded == 0, "\(decodes)")
        #expect(decodes.walked == 2, "\(decodes)")
    }

    @Test("A payload past the client limit on the public API is refused by the walk")
    func directDeepCallRefused() async throws {
        let fixture = try await makeBoundedFixture(encoding: .json)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BoundedDeepAction.self),
            payload: AnyCodable(["tag": "deep", "deep": nestedArrays(PayloadNesting.clientFrameMaxDepth)] as [String: Any])
        )
        await #expect(throws: PayloadNesting.TooDeep.self) {
            _ = try await fixture.keeper.handleActionEnvelope(
                envelope,
                playerID: PlayerID("p-bounded"),
                clientID: ClientID("c-bounded"),
                sessionID: fixture.session
            )
        }
        #expect(await fixture.keeper.currentState().hits.isEmpty)
    }

    /// The nesting depth of a frame, counted as its decoder counts it.
    static func depth(of frame: Data, encoding: TransportEncodingConfig) throws -> Int {
        if encoding.message == .messagepack {
            for depth in 1...PayloadNesting.serverFrameMaxDepth {
                if (try? unpack(frame, maxDepth: depth)) != nil { return depth }
            }
            throw PayloadNesting.TooDeep(limit: PayloadNesting.serverFrameMaxDepth)
        }
        for depth in 1...PayloadNesting.serverFrameMaxDepth {
            if (try? PayloadNesting.checkJSON(frame, limit: depth)) != nil { return depth }
        }
        throw PayloadNesting.TooDeep(limit: PayloadNesting.serverFrameMaxDepth)
    }
}
