// Tests/SwiftStateTreeTransportTests/BoundedPayloadDecodeTests.swift
//
// A live input's payload is checked for depth once, by its frame's decode (#362). The adapter's
// decode pipeline bounds the whole frame at `PayloadNesting.clientFrameMaxDepth` and hands the
// keeper the proof (`DepthBounded`), so the payload decode doesn't walk the payload again. The
// proof is granted only where this package's code bounded the exact bytes: a frame another
// module's codec decoded, or one the JSON scan didn't read, is walked, and so is a payload handed
// to the keeper's public API.
//
// Each test counts the depth walks themselves (`PayloadNesting.walks`, bound for the test's task
// and the tasks it starts), so a walk added anywhere on the bounded path shows, whichever decode
// overload ran.

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

/// The same, with a resolver: it runs as an action job (`startActionJob`).
@Payload
struct BoundedJobAction: ActionPayload {
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

struct BoundedJobOutput: ResolverOutput {}

struct BoundedJobResolver: ContextResolver {
    typealias Output = BoundedJobOutput
    static func resolve(ctx: ResolverContext) async throws -> BoundedJobOutput { BoundedJobOutput() }
}

/// Another module's MessagePack codec: the protocol's default `decodeClientFrame`, which doesn't
/// bound a MessagePack unpack at the client limit (it decodes at the server frames' 64).
private struct ForeignMessagePackCodec: TransportCodec {
    let encoding: TransportEncoding = .messagepack
    func encode<T: Encodable>(_ value: T) throws -> Data { try MessagePackTransportCodec().encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try MessagePackTransportCodec().decode(type, from: data) }
}

/// Another module's JSON codec that reads JSON5: it accepts a frame that starts with a comment,
/// which the JSON scan doesn't read (it isn't a container).
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
private actor BoundedFrames: Transport {
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
enum BoundedCodecChoice: Sendable, CustomTestStringConvertible {
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
}

private struct BoundedFixture {
    let keeper: LandKeeper<BoundedDecodeState>
    let adapter: TransportAdapter<BoundedDecodeState>
    let sent: BoundedFrames
    let choice: BoundedCodecChoice
    let session = SessionID("s-bounded")

    func frame(_ message: TransportMessage) throws -> Data {
        let data = try choice.codec.encode(message)
        // The JSON5 codec's frames start with a comment: the JSON scan doesn't read them.
        if case .foreignJSON5 = choice { return Data("/* c */ ".utf8) + data }
        return data
    }

    func actionFrame(_ tag: String, deep: Any, job: Bool = false) throws -> Data {
        let envelope = ActionEnvelope(
            typeIdentifier: job ? String(describing: BoundedJobAction.self) : String(describing: BoundedDeepAction.self),
            payload: AnyCodable(["tag": tag, "deep": deep] as [String: Any])
        )
        return try frame(TransportMessage.action(requestID: "a-\(tag)", action: envelope))
    }

    func eventFrame(_ tag: String, deep: Any) throws -> Data {
        let event = AnyClientEvent(
            type: payloadEventName(for: BoundedDeepEvent.self),
            payload: AnyCodable(["tag": tag, "deep": deep] as [String: Any])
        )
        return try frame(TransportMessage.event(event: .fromClient(event: event)))
    }
}

/// A tickless land: an action without resolvers is applied before the adapter's `onMessage`
/// returns, and so is a client event sent before it. A job's action is answered later.
private func makeBoundedFixture(_ choice: BoundedCodecChoice, legacyJoin: Bool = false) async throws -> BoundedFixture {
    let definition = Land("bounded-decode", using: BoundedDecodeState.self) {
        ClientEvents { Register(BoundedDeepEvent.self) }
        Rules {
            HandleAction(BoundedDeepAction.self) { (state: inout BoundedDecodeState, action: BoundedDeepAction, _: LandContext) in
                state.hits.append("action:\(action.tag)")
                return BoundedDeepResponse(count: state.hits.count)
            }
            HandleAction(BoundedJobAction.self, resolvers: BoundedJobResolver.self) { (state: inout BoundedDecodeState, action: BoundedJobAction, _: LandContext) in
                state.hits.append("job:\(action.tag)")
                return BoundedDeepResponse(count: state.hits.count)
            }
            HandleEvent(BoundedDeepEvent.self) { (state: inout BoundedDecodeState, event: BoundedDeepEvent, _: LandContext) in
                state.hits.append("event:\(event.tag)")
            }
        }
    }
    let sent = BoundedFrames()
    let keeper = LandKeeper(definition: definition, initialState: BoundedDecodeState())
    let adapter: TransportAdapter<BoundedDecodeState>
    if let config = choice.config {
        adapter = TransportAdapter(keeper: keeper, transport: sent, landID: "bounded-decode", enableLegacyJoin: legacyJoin, encodingConfig: config)
    } else {
        adapter = TransportAdapter(keeper: keeper, transport: sent, landID: "bounded-decode", enableLegacyJoin: legacyJoin, codec: choice.codec)
    }
    await sent.setDelegate(adapter)
    await keeper.setTransport(adapter)
    let fixture = BoundedFixture(keeper: keeper, adapter: adapter, sent: sent, choice: choice)
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

/// Runs `body` with the depth walks counted (`PayloadNesting.walks`) for its task and the tasks
/// it starts.
private func countingWalks(_ body: (PayloadNesting.WalkCounter) async throws -> Void) async throws {
    let walks = PayloadNesting.WalkCounter()
    try await PayloadNesting.$walks.withValue(walks) { try await body(walks) }
}

/// `[[...[]...]]`: `levels` arrays.
private func nestedArrays(_ levels: Int) -> Any {
    var value: Any = [Any]()
    for _ in 1..<max(1, levels) { value = [value] }
    return value
}

@Suite("A live input's payload is checked once, by its frame's decode (#362)", .timeLimit(.minutes(1)))
struct BoundedPayloadDecodeTests {
    static let ownEncodings: [TransportEncoding] = [.json, .opcodeJsonArray, .messagepack]

    @Test("A payload from a frame at the client limit decodes with its frame's bound, not walked again",
          arguments: ownEncodings, [false, true])
    func liveInputsComeBounded(encoding: TransportEncoding, legacyJoin: Bool) async throws {
        try await countingWalks { walks in
            let fixture = try await makeBoundedFixture(.config(encoding), legacyJoin: legacyJoin)
            // The deepest frame the client limit takes: the frame's own levels around `deep`, plus
            // `deep`'s arrays, total exactly the limit.
            let limit = PayloadNesting.clientFrameMaxDepth
            let probe = try fixture.actionFrame("probe", deep: [Any]())
            let around = try Self.depth(of: probe, encoding: encoding) - 1
            let action = try fixture.actionFrame("deep", deep: nestedArrays(limit - around))
            #expect(try Self.depth(of: action, encoding: encoding) == limit)
            let event = try fixture.eventFrame("deep", deep: nestedArrays(2))

            await fixture.adapter.onMessage(event, from: fixture.session)
            await fixture.adapter.onMessage(action, from: fixture.session)

            #expect(await fixture.keeper.currentState().hits == ["event:deep", "action:deep"])
            // No live decode walked: not the action at intake or when applied, not the event. A
            // decode that walked anyway, or an adapter that stopped handing the keeper the bounded
            // form, would count here.
            #expect(walks.count == 0)
        }
    }

    @Test("An action job keeps its frame's bound through its resolvers to the apply", arguments: ownEncodings)
    func jobKeepsTheBound(encoding: TransportEncoding) async throws {
        try await countingWalks { walks in
            let fixture = try await makeBoundedFixture(.config(encoding))
            let before = await fixture.sent.frames.count
            await fixture.adapter.onMessage(try fixture.actionFrame("j", deep: nestedArrays(3), job: true), from: fixture.session)
            // The job's answer is the frame after the ones sent so far: the action was applied.
            await fixture.sent.waitForFrames(before + 1)
            #expect(await fixture.keeper.currentState().hits == ["job:j"])
            #expect(walks.count == 0)
        }
    }

    @Test("Another module's codec, or a frame the scan didn't read, gets no proof: its payloads are walked",
          arguments: [BoundedCodecChoice.foreignMessagePack, .foreignJSON5], [false, true])
    func foreignCodecsAreWalked(choice: BoundedCodecChoice, legacyJoin: Bool) async throws {
        try await countingWalks { walks in
            let fixture = try await makeBoundedFixture(choice, legacyJoin: legacyJoin)
            await fixture.adapter.onMessage(try fixture.eventFrame("ok", deep: nestedArrays(2)), from: fixture.session)
            await fixture.adapter.onMessage(try fixture.actionFrame("ok", deep: nestedArrays(2)), from: fixture.session)
            #expect(await fixture.keeper.currentState().hits == ["event:ok", "action:ok"])
            // The event once, the action at intake and when applied.
            #expect(walks.count == 3)
        }
    }

    @Test("Through another module's codec, a payload past the client limit is still refused, at every granting site",
          arguments: [BoundedCodecChoice.foreignMessagePack, .foreignJSON5], [false, true])
    func foreignDeepRefused(choice: BoundedCodecChoice, legacyJoin: Bool) async throws {
        try await countingWalks { walks in
            let fixture = try await makeBoundedFixture(choice, legacyJoin: legacyJoin)
            // 40 levels in all: past the client limit, under what the foreign decoders take.
            let deep = nestedArrays(PayloadNesting.clientFrameMaxDepth + 8)
            let droppedBefore = PayloadNesting.droppedClientEventCount
            await fixture.adapter.onMessage(try fixture.eventFrame("deep", deep: deep), from: fixture.session)
            await fixture.adapter.onMessage(try fixture.actionFrame("deep", deep: deep), from: fixture.session)
            // A shallow action after them: its apply (a turn, or the legacy pass) applies the queued
            // event too, so the event's drop has happened when it returns.
            await fixture.adapter.onMessage(try fixture.actionFrame("after", deep: nestedArrays(2)), from: fixture.session)
            #expect(await fixture.keeper.currentState().hits == ["action:after"])
            #expect(PayloadNesting.droppedClientEventCount >= droppedBefore + 1)
            // The deep event and action were each walked and refused; the shallow one walked twice.
            #expect(walks.count == 4)
        }
    }

    @Test("A payload handed to the keeper's public API, without its frame, is walked")
    func directCallsAreWalked() async throws {
        try await countingWalks { walks in
            let fixture = try await makeBoundedFixture(.config(.json))
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
            #expect(walks.count == 2)
        }
    }

    @Test("A payload past the client limit on the public API is refused by the walk")
    func directDeepCallRefused() async throws {
        let fixture = try await makeBoundedFixture(.config(.json))
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

    @Test("Only the decode pipeline builds the proof: no other source file names its initializer")
    func proofBuiltOnlyByThePipeline() throws {
        // The initializer is `package`, so this rule is kept by review and by this test. It
        // matches the label alone, so a call split across lines is caught too. It can't see
        // `DepthBounded.map` used to wrap another value (`map { _ in other }`): review keeps
        // `map` to projections (`DepthBounded`'s doc).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let allowed: Set<String> = ["SwiftStateTree/Support/DepthBounded.swift", "SwiftStateTreeTransport/Pipeline/MessageDecodingPipeline.swift"]
        var callers: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("decodedFromBoundedFrame") {
                callers.append(String(url.path.dropFirst(sources.path.count + 1)))
            }
        }
        #expect(!callers.isEmpty, "no source under \(sources.path)")
        #expect(Set(callers).subtracting(allowed).isEmpty, "\(callers.sorted())")
    }

    /// The nesting depth of a frame, counted as its decoder counts it.
    static func depth(of frame: Data, encoding: TransportEncoding) throws -> Int {
        if encoding == .messagepack {
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
