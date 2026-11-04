// Tests/SwiftStateTreeTransportTests/TransportAdapterTargetedEventOnceTests.swift
//
// Regression tests for #70: with opcode 107 (opcodeMessagePack state updates), a targeted event
// queued for a cycle must reach its session exactly once. `buildSendBatch` puts a session's
// targeted event frames before its per-player state frame; `flushTargetedEventBodiesIfNeeded`
// then sent the same bodies again to every joined session, including those already served.
//
// Protocol order: events of a cycle precede that cycle's state frame.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test state, action and event

@StateNodeBuilder
struct TargetedOnceTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct TargetedOnceSetScoreAction: ActionPayload {
    typealias Response = TargetedOnceSetScoreResponse
    let value: Int
}

@Payload
struct TargetedOnceSetScoreResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct TargetedOnceEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

/// Unique text carried by the targeted event; a frame contains it iff it carries the event.
private let targetedOnceMarker = "targeted-once-marker-7f3a"

/// Records every frame in send order (the fixture has a single client). When armed with
/// `holdNextBatch()`, the next `sendBatch` records its frames and suspends until `release()`.
private actor TargetedOnceRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var frames: [Data] = []
    private var shouldHoldNextBatch = false
    private var heldBatch: CheckedContinuation<Void, Never>?
    private var holdWaiter: CheckedContinuation<Void, Never>?

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append(message)
    }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, _) in updates {
            frames.append(data)
        }
        guard shouldHoldNextBatch else { return }
        shouldHoldNextBatch = false
        await withCheckedContinuation { continuation in
            heldBatch = continuation
            holdWaiter?.resume()
            holdWaiter = nil
        }
    }
    func holdNextBatch() { shouldHoldNextBatch = true }
    func waitUntilHeld() async {
        if heldBatch != nil { return }
        await withCheckedContinuation { continuation in
            holdWaiter = continuation
        }
    }
    func release() {
        heldBatch?.resume()
        heldBatch = nil
    }
    func recordedFrames() -> [Data] { frames }
    func clear() { frames.removeAll() }
}

private struct TargetedOnceFixture {
    let keeper: LandKeeper<TargetedOnceTestState>
    let adapter: TransportAdapter<TargetedOnceTestState>
    let transport: TargetedOnceRecordingTransport
    let session = SessionID("to-session")
    let client = ClientID("to-client")
    let player = PlayerID("to-player")

    static func make(encoding: TransportEncodingConfig) async throws -> TargetedOnceFixture {
        let definition = Land("targeted-once-test", using: TargetedOnceTestState.self) {
            ServerEvents {
                Register(TargetedOnceEvent.self)
            }
            Rules {
                OnJoin { (state: inout TargetedOnceTestState, ctx: LandContext) in
                    state.scores[ctx.playerID] = 0
                }
                HandleAction(TargetedOnceSetScoreAction.self) { (state: inout TargetedOnceTestState, action: TargetedOnceSetScoreAction, ctx: LandContext) in
                    state.scores[ctx.playerID] = action.value
                    return TargetedOnceSetScoreResponse(ok: true)
                }
            }
        }
        let transport = TargetedOnceRecordingTransport()
        let keeper = LandKeeper<TargetedOnceTestState>(definition: definition, initialState: TargetedOnceTestState())
        let adapter = TransportAdapter<TargetedOnceTestState>(
            keeper: keeper,
            transport: transport,
            landID: "targeted-once-test",
            encodingConfig: encoding
        )
        await transport.setDelegate(adapter)
        let fixture = TargetedOnceFixture(keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: fixture.client,
            playerID: fixture.player
        )
        // Settle the post-join cycle, then look only at what the checked cycle sends.
        await adapter.syncNow()
        await transport.clear()
        return fixture
    }

    func setScore(_ value: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: TargetedOnceSetScoreAction.self),
            payload: AnyCodable(TargetedOnceSetScoreAction(value: value))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }

    func sendTargetedEvent(_ message: String = targetedOnceMarker) async {
        await adapter.sendEvent(AnyServerEvent(TargetedOnceEvent(message: message)), to: .player(player))
    }

    /// Indices (in send order) of frames that carry the targeted event with `message`.
    func eventFrameIndices(_ message: String = targetedOnceMarker) async -> [Int] {
        let marker = Data(message.utf8)
        return (await transport.recordedFrames()).enumerated().compactMap { index, frame in
            frame.range(of: marker) != nil ? index : nil
        }
    }
}

/// Indices of opcodeMessagePack state update frames (first element 0 noChange, 1 firstSync, 2 diff).
private func messagePackStateFrameIndices(_ frames: [Data]) -> [Int] {
    frames.enumerated().compactMap { index, frame in
        guard let unpacked = try? unpack(frame),
              case .array(let array) = unpacked,
              case .int(let opcode) = array.first,
              (0...2).contains(opcode) else { return nil }
        return index
    }
}

// MARK: - Tests

@Suite("TransportAdapter targeted events are sent once per cycle (#70)", .timeLimit(.minutes(1)))
struct TransportAdapterTargetedEventOnceTests {

    @Test("opcode 107: a targeted event plus a per-player change arrives exactly once, before the state frame")
    func targetedEventWithStateChangeArrivesOnceBeforeStateFrame() async throws {
        let f = try await TargetedOnceFixture.make(encoding: .messagepack)

        try await f.setScore(5)
        await f.sendTargetedEvent()
        await f.adapter.syncNow()

        let frames = await f.transport.recordedFrames()
        let eventIndices = await f.eventFrameIndices()
        let stateIndices = messagePackStateFrameIndices(frames)
        #expect(eventIndices.count == 1, "targeted event must arrive exactly once; event frames at \(eventIndices) of \(frames.count)")
        #expect(stateIndices.count == 1, "expected one per-player state frame; state frames at \(stateIndices)")
        if let event = eventIndices.first, let state = stateIndices.first {
            #expect(event < state, "event frame (\(event)) must precede the state frame (\(state))")
        }
    }

    @Test("opcode 107: a targeted event in a cycle with no state change for the session arrives exactly once")
    func targetedEventWithoutStateChangeArrivesOnce() async throws {
        let f = try await TargetedOnceFixture.make(encoding: .messagepack)

        await f.sendTargetedEvent()
        await f.adapter.syncNow()

        let frames = await f.transport.recordedFrames()
        let eventIndices = await f.eventFrameIndices()
        #expect(eventIndices.count == 1, "targeted event must arrive exactly once; event frames at \(eventIndices) of \(frames.count)")
        #expect(messagePackStateFrameIndices(frames).isEmpty, "no state frame expected without a state change")
    }

    @Test("opcode 107: a targeted event queued while the batch is in flight is still sent, once")
    func targetedEventQueuedDuringBatchIsSentOnce() async throws {
        let f = try await TargetedOnceFixture.make(encoding: .messagepack)
        let lateMarker = "targeted-once-late-marker-c41d"

        try await f.setScore(5)
        await f.sendTargetedEvent()
        await f.transport.holdNextBatch()
        let adapter = f.adapter
        let cycle = Task { await adapter.syncNow() }
        await f.transport.waitUntilHeld()
        // Queued after the batch was built: the flush must send it, and only it.
        await f.sendTargetedEvent(lateMarker)
        await f.transport.release()
        await cycle.value

        let earlyIndices = await f.eventFrameIndices()
        let lateIndices = await f.eventFrameIndices(lateMarker)
        #expect(earlyIndices.count == 1, "batched event must arrive exactly once; frames at \(earlyIndices)")
        #expect(lateIndices.count == 1, "event queued during the batch must arrive exactly once; frames at \(lateIndices)")
    }

    @Test(
        "json / opcodeJsonArray: a targeted event plus a per-player change arrives exactly once, before the state frame",
        arguments: ["json", "jsonOpcode"]
    )
    func nonMergedEncodingsUnchanged(encodingName: String) async throws {
        let encoding: TransportEncodingConfig = encodingName == "json" ? .json : .jsonOpcode
        let f = try await TargetedOnceFixture.make(encoding: encoding)

        try await f.setScore(5)
        await f.sendTargetedEvent()
        await f.adapter.syncNow()

        let frames = await f.transport.recordedFrames()
        let eventIndices = await f.eventFrameIndices()
        #expect(eventIndices.count == 1, "targeted event must arrive exactly once; event frames at \(eventIndices) of \(frames.count)")
        // On these encodings the event is sent when emitted, so the state frame follows it.
        if let event = eventIndices.first {
            #expect(event < frames.count - 1, "a state frame must follow the event frame; frames \(frames.count), event at \(event)")
        }
    }
}
