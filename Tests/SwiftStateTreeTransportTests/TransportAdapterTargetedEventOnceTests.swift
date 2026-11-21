// Tests/SwiftStateTreeTransportTests/TransportAdapterTargetedEventOnceTests.swift
//
// Regression tests for #70: with opcode 107 (opcodeMessagePack state updates), a targeted event
// queued for a cycle must reach its session exactly once. The batch put a session's targeted
// event frames before its per-player state frame; a later flush then sent the same bodies again
// to every joined session, including those already served.
//
// Order (see `planSyncPhase`): the plan reads the queue once; each session's targeted event
// frames precede its per-player state frame. Events queued after the plan read the queue arrive
// in the next cycle.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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

/// Records every frame in send order.
private actor TargetedOnceRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var frames: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append((target, message))
    }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            frames.append((target, data))
        }
    }
    /// All frames in send order (for single-session fixtures).
    func recordedFrames() -> [Data] { frames.map(\.data) }
    /// Frames addressed to `sessionID`, in send order.
    func frames(for sessionID: SessionID) -> [Data] {
        frames.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
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
            // Delta, dirty tracking on and snapshot extraction on, fixed. The tables and typed
            // leaves follow USE_SYNC_TABLES / TYPED_LEAF_VALUES on purpose, so the off job runs
            // this on the fallback.
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                profilingConfig: nil
            ),
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
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await transport.clear()
        return fixture
    }

    /// Joins a second session and settles its initial sync.
    func joinSecondSession(session: SessionID, client: ClientID, player: PlayerID) async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await transport.clear()
    }

    func setScore(_ value: Int) async throws {
        try await setScore(value, player: player, client: client, session: session)
    }

    func setScore(_ value: Int, player: PlayerID, client: ClientID, session: SessionID) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: TargetedOnceSetScoreAction.self),
            payload: AnyCodable(TargetedOnceSetScoreAction(value: value))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }

    func sendTargetedEvent(_ message: String = targetedOnceMarker) async {
        await sendTargetedEvent(message, to: player)
    }

    func sendTargetedEvent(_ message: String, to target: PlayerID) async {
        await adapter.sendEvent(AnyServerEvent(TargetedOnceEvent(message: message)), to: .player(target))
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// Waits until a frame carrying `message` reached `sessionID` (the follow-up cycle runs in
    /// its own task), then a little longer so a late duplicate is seen too.
    func waitForEvent(_ message: String, at sessionID: SessionID) async throws {
        let marker = Data(message.utf8)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await transport.frames(for: sessionID)).contains(where: { $0.range(of: marker) != nil }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(message) at \(sessionID.rawValue)")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// Indices (in send order) of frames that carry the targeted event with `message`.
    func eventFrameIndices(_ message: String = targetedOnceMarker) async -> [Int] {
        let marker = Data(message.utf8)
        return (await transport.recordedFrames()).enumerated().compactMap { index, frame in
            frame.range(of: marker) != nil ? index : nil
        }
    }
}

/// Indices of frames that contain `message`.
private func frameIndices(containing message: String, in frames: [Data]) -> [Int] {
    let marker = Data(message.utf8)
    return frames.enumerated().compactMap { index, frame in
        frame.range(of: marker) != nil ? index : nil
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
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")

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
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")

        let frames = await f.transport.recordedFrames()
        let eventIndices = await f.eventFrameIndices()
        #expect(eventIndices.count == 1, "targeted event must arrive exactly once; event frames at \(eventIndices) of \(frames.count)")
        #expect(messagePackStateFrameIndices(frames).isEmpty, "no state frame expected without a state change")
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
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")

        let frames = await f.transport.recordedFrames()
        let eventIndices = await f.eventFrameIndices()
        #expect(eventIndices.count == 1, "targeted event must arrive exactly once; event frames at \(eventIndices) of \(frames.count)")
        // On these encodings the event is sent when emitted, so the state frame follows it.
        if let event = eventIndices.first {
            #expect(event < frames.count - 1, "a state frame must follow the event frame; frames \(frames.count), event at \(event)")
        }
    }
}
