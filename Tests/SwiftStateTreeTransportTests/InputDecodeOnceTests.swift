// Tests/SwiftStateTreeTransportTests/InputDecodeOnceTests.swift
//
// A live input is decoded into its type once, at intake, from the source its frame's decoder
// built (#521 PR 2): a MessagePack value straight into the type, an `AnyCodable` tree with the
// JSON round trip. The apply step runs that value. A client event that doesn't decode is refused
// at intake with an error frame, never applied (#537).
//
// The walk counts (`PayloadNesting.walks`: the depth check, and a MessagePack source's walk) pin
// one walk per input on every encoding. Before this change an action was walked twice, at intake
// and again when applied, with or without resolvers; a decode added back at apply shows here as 2.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct DecodeOnceState: StateNodeProtocol {
    @Sync(.broadcast)
    var hits: [String] = []
}

@Payload
struct DecodeOnceAction: ActionPayload {
    typealias Response = DecodeOnceResponse
    let tag: String
    let deep: AnyCodable
}

/// The same, with a resolver: it runs as an action job (`startActionJob`).
@Payload
struct DecodeOnceJobAction: ActionPayload {
    typealias Response = DecodeOnceResponse
    let tag: String
    let deep: AnyCodable
}

@Payload
struct DecodeOnceResponse: ResponsePayload {
    let count: Int
}

@Payload
struct DecodeOnceEvent: ClientEventPayload {
    let tag: String
    let deep: AnyCodable
}

struct DecodeOnceJobOutput: ResolverOutput {}

struct DecodeOnceJobResolver: ContextResolver {
    typealias Output = DecodeOnceJobOutput
    static func resolve(ctx: ResolverContext) async throws -> DecodeOnceJobOutput { DecodeOnceJobOutput() }
}

/// Another module's MessagePack codec: the protocol's default `decodeClientFrame`.
private struct ForeignMessagePackCodec: TransportCodec {
    let encoding: TransportEncoding = .messagepack
    func encode<T: Encodable>(_ value: T) throws -> Data { try MessagePackTransportCodec().encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try MessagePackTransportCodec().decode(type, from: data) }
}

/// Another module's JSON codec that reads JSON5, so a frame may start with a comment.
private struct ForeignJSON5Codec: TransportCodec {
    let encoding: TransportEncoding = .json
    func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try decoder.decode(type, from: data)
    }
}

/// Records every frame sent, and wakes a waiter when a given count is reached.
private actor DecodeOnceFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [Data] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { append(message) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, _) in updates { append(data) }
    }

    private func append(_ data: Data) {
        frames.append(data)
        let ready = waiters.filter { frames.count >= $0.count }
        waiters.removeAll { frames.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Returns once at least `count` frames were sent.
    func waitForFrames(_ count: Int) async {
        if frames.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// How the adapter decodes: an encoding of this module, or another module's codec.
enum DecodeOnceCodec: Sendable, CustomTestStringConvertible {
    case config(TransportEncoding)
    case foreignMessagePack
    case foreignJSON5

    var testDescription: String {
        switch self {
        case .config(let encoding): return encoding.rawValue
        case .foreignMessagePack: return "foreign messagepack codec"
        case .foreignJSON5: return "foreign JSON5 codec"
        }
    }

    var codec: any TransportCodec {
        switch self {
        case .config(let encoding): return encoding.makeCodec()
        case .foreignMessagePack: return ForeignMessagePackCodec()
        case .foreignJSON5: return ForeignJSON5Codec()
        }
    }

    var config: TransportEncodingConfig? {
        switch self {
        case .config(.json): return .json
        case .config(.opcodeJsonArray): return .opcode
        case .config(.messagepack): return .messagepack
        default: return nil
        }
    }

    static let all: [DecodeOnceCodec] = [.config(.json), .config(.opcodeJsonArray), .config(.messagepack), .foreignMessagePack, .foreignJSON5]
}

private struct DecodeOnceFixture {
    let keeper: LandKeeper<DecodeOnceState>
    let adapter: TransportAdapter<DecodeOnceState>
    let sent: DecodeOnceFrames
    let choice: DecodeOnceCodec
    let session = SessionID("s-decode-once")

    func frame(_ message: TransportMessage) throws -> Data {
        let data = try choice.codec.encode(message)
        if case .foreignJSON5 = choice { return Data("/* c */ ".utf8) + data }
        return data
    }

    func actionFrame(_ tag: String, deep: Any = [Any](), job: Bool = false) throws -> Data {
        let envelope = ActionEnvelope(
            typeIdentifier: job ? String(describing: DecodeOnceJobAction.self) : String(describing: DecodeOnceAction.self),
            payload: AnyCodable(["tag": tag, "deep": deep] as [String: Any])
        )
        return try frame(TransportMessage.action(requestID: "a-\(tag)", action: envelope))
    }

    func eventFrame(_ payload: [String: Any]) throws -> Data {
        let event = AnyClientEvent(type: payloadEventName(for: DecodeOnceEvent.self), payload: AnyCodable(payload))
        return try frame(TransportMessage.event(event: .fromClient(event: event)))
    }

    func eventFrame(_ tag: String, deep: Any = [Any]()) throws -> Data {
        try eventFrame(["tag": tag, "deep": deep])
    }

    /// The error frames sent so far, decoded.
    func errors() async -> [ErrorPayload] {
        await sent.frames.compactMap { data in
            // An opcode JSON frame (`[106, …]`) is read by the opcode decoder.
            let message = (try? choice.codec.decode(TransportMessage.self, from: data))
                ?? (try? OpcodeTransportMessageDecoder().decode(from: data))
            guard let message, case .error(let payload) = message.payload else { return nil }
            return payload
        }
    }
}

/// A tickless land: an action without resolvers is applied before the adapter's `onMessage`
/// returns, and so is a client event sent before it. A job's action is answered later.
private func makeFixture(_ choice: DecodeOnceCodec, legacyJoin: Bool = false) async throws -> DecodeOnceFixture {
    let definition = Land("decode-once", using: DecodeOnceState.self) {
        ClientEvents { Register(DecodeOnceEvent.self) }
        Rules {
            HandleAction(DecodeOnceAction.self) { (state: inout DecodeOnceState, action: DecodeOnceAction, _: LandContext) in
                state.hits.append("action:\(action.tag)")
                return DecodeOnceResponse(count: state.hits.count)
            }
            HandleAction(DecodeOnceJobAction.self, resolvers: DecodeOnceJobResolver.self) { (state: inout DecodeOnceState, action: DecodeOnceJobAction, _: LandContext) in
                state.hits.append("job:\(action.tag)")
                return DecodeOnceResponse(count: state.hits.count)
            }
            HandleEvent(DecodeOnceEvent.self) { (state: inout DecodeOnceState, event: DecodeOnceEvent, _: LandContext) in
                state.hits.append("event:\(event.tag)")
            }
        }
    }
    let sent = DecodeOnceFrames()
    let keeper = LandKeeper(definition: definition, initialState: DecodeOnceState())
    let adapter: TransportAdapter<DecodeOnceState>
    if let config = choice.config {
        adapter = TransportAdapter(keeper: keeper, transport: sent, landID: "decode-once", enableLegacyJoin: legacyJoin, encodingConfig: config)
    } else {
        adapter = TransportAdapter(keeper: keeper, transport: sent, landID: "decode-once", enableLegacyJoin: legacyJoin, codec: choice.codec)
    }
    await sent.setDelegate(adapter)
    await keeper.setTransport(adapter)
    let fixture = DecodeOnceFixture(keeper: keeper, adapter: adapter, sent: sent, choice: choice)
    let client = ClientID("c-decode-once")
    await adapter.onConnect(sessionID: fixture.session, clientID: client)
    _ = try await adapter.performJoin(
        playerSession: PlayerSession(playerID: "p-decode-once", deviceID: "dev", metadata: [:]),
        clientID: client,
        sessionID: fixture.session,
        authInfo: nil,
        joinResponse: { _, _ in Data("{}".utf8) }
    )
    return fixture
}

/// Runs `body` with the walks counted (`PayloadNesting.walks`) for its task and the tasks it
/// starts.
private func countingWalks(_ body: (PayloadNesting.WalkCounter) async throws -> Void) async throws {
    let walks = PayloadNesting.WalkCounter()
    try await PayloadNesting.$walks.withValue(walks) { try await body(walks) }
}

@Suite("A live input is decoded once, at intake, from its frame's source (#521 PR 2)", .timeLimit(.minutes(1)))
struct InputDecodeOnceTests {
    @Test("An action and a client event are walked once each, with or without the legacy join",
          arguments: DecodeOnceCodec.all, [false, true])
    func walkedOncePerInput(choice: DecodeOnceCodec, legacyJoin: Bool) async throws {
        try await countingWalks { walks in
            let fixture = try await makeFixture(choice, legacyJoin: legacyJoin)
            await fixture.adapter.onMessage(try fixture.eventFrame("e", deep: [[1]]), from: fixture.session)
            await fixture.adapter.onMessage(try fixture.actionFrame("a", deep: [[1]]), from: fixture.session)
            #expect(await fixture.keeper.currentState().hits == ["event:e", "action:a"])
            // One walk for the event and one for the action. A decode at apply, as before, would
            // add one for the action.
            #expect(walks.count == 2)
        }
    }

    @Test("An action job is walked once: its resolvers and its apply run the value decoded at intake",
          arguments: DecodeOnceCodec.all)
    func jobWalkedOnce(choice: DecodeOnceCodec) async throws {
        try await countingWalks { walks in
            let fixture = try await makeFixture(choice)
            let before = await fixture.sent.frames.count
            await fixture.adapter.onMessage(try fixture.actionFrame("j", deep: [[1]], job: true), from: fixture.session)
            // The job's answer is the frame after the ones sent so far: the action was applied.
            await fixture.sent.waitForFrames(before + 1)
            #expect(await fixture.keeper.currentState().hits == ["job:j"])
            // Counted in the job's tasks too (they inherit the binding): the intake's walk, and no
            // other. A job applied in a task that didn't inherit it would count 0 (#616 review).
            #expect(walks.count == 1)
        }
    }

    @Test("A payload handed to the keeper's public API is walked once")
    func publicAPIWalkedOnce() async throws {
        try await countingWalks { walks in
            let fixture = try await makeFixture(.config(.json))
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: DecodeOnceAction.self),
                payload: AnyCodable(["tag": "direct", "deep": [Any]()] as [String: Any])
            )
            _ = try await fixture.keeper.handleActionEnvelope(
                envelope,
                playerID: PlayerID("p-decode-once"),
                clientID: ClientID("c-decode-once"),
                sessionID: fixture.session
            )
            #expect(await fixture.keeper.currentState().hits == ["action:direct"])
            #expect(walks.count == 1)
        }
    }

    @Test("A client event whose payload doesn't decode is refused with EVENT_INVALID_PAYLOAD, and isn't applied",
          arguments: DecodeOnceCodec.all)
    func undecodableEventRefused(choice: DecodeOnceCodec) async throws {
        let fixture = try await makeFixture(choice)
        // `tag` must be a string; `deep` is missing.
        await fixture.adapter.onMessage(try fixture.eventFrame(["tag": 5]), from: fixture.session)
        // An action after it: its apply would apply the event too, had it been queued.
        await fixture.adapter.onMessage(try fixture.actionFrame("after"), from: fixture.session)
        #expect(await fixture.keeper.currentState().hits == ["action:after"])
        let errors = await fixture.errors()
        #expect(errors.map(\.code) == [.eventInvalidPayload])
    }

    @Test("A MessagePack client event or action holding a non-finite number is refused, as the round trip refused it",
          arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteRefused(number: Double) async throws {
        let fixture = try await makeFixture(.config(.messagepack))
        // Under a key the type doesn't declare: today's round trip encodes the whole tree.
        await fixture.adapter.onMessage(try fixture.eventFrame(["tag": "nan", "deep": [Any](), "extra": number]), from: fixture.session)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: DecodeOnceAction.self),
            payload: AnyCodable(["tag": "nan", "deep": [Any](), "extra": number] as [String: Any])
        )
        await fixture.adapter.onMessage(try fixture.frame(TransportMessage.action(requestID: "a-nan", action: envelope)), from: fixture.session)
        await fixture.adapter.onMessage(try fixture.actionFrame("after"), from: fixture.session)
        #expect(await fixture.keeper.currentState().hits == ["action:after"])
        let codes = await fixture.errors().map(\.code)
        #expect(codes.contains(ErrorCode.eventInvalidPayload.rawValue))
        #expect(codes.count == 2)
    }
}
