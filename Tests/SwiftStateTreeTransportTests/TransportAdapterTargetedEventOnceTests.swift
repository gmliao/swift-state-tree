// Tests/SwiftStateTreeTransportTests/TransportAdapterTargetedEventOnceTests.swift
//
// Regression tests for #70: with opcode 107 (opcodeMessagePack state updates), a targeted event
// queued for a cycle must reach its session exactly once. `buildSendBatch` puts a session's
// targeted event frames before its per-player state frame; `flushTargetedEventBodiesIfNeeded`
// then sent the same bodies again to every joined session, including those already served.
//
// Order (see `runSyncNowCycle`): targeted events queued before the batch precede the session's
// per-player state frame; events queued later in the cycle follow it.

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

/// Records every frame in send order. Cycles are held in flight with `SyncCycleHold`.
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
    let hold = SyncCycleHold()
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
            // Fixed so env vars cannot change the sync path: delta, dirty tracking on,
            // snapshot extraction on, auto-switch and metrics off.
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            ),
            encodingConfig: encoding
        )
        await transport.setDelegate(adapter)
        let fixture = TargetedOnceFixture(keeper: keeper, adapter: adapter, transport: transport)
        await fixture.hold.install(on: adapter)
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

    /// Runs `syncNow` held in flight (after it read the event queue, before `endSync`; see
    /// `SyncCycleHold`), runs `duringCycle`, then lets the cycle finish.
    func syncNowHolding(_ duringCycle: () async throws -> Void) async throws {
        hold.arm()
        let adapter = self.adapter
        let cycle = Task { await adapter.syncNow() }
        do {
            try await hold.waitUntilHeld()
            try await duringCycle()
        } catch {
            hold.release()
            await cycle.value
            throw error
        }
        hold.release()
        await cycle.value
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

    // Before #60 the cycle awaited the transport between the per-player batch and the flush,
    // and this test queued the late event in that window (served by the flush). The cycle no
    // longer suspends there, so the late event is queued while the cycle is held before
    // `endSync`, after it read the queue: it is kept and the follow-up cycle sends it, once.
    @Test("opcode 107: a targeted event queued while a cycle is in flight, after it read the queue, is still sent, once")
    func targetedEventQueuedDuringBatchIsSentOnce() async throws {
        let f = try await TargetedOnceFixture.make(encoding: .messagepack)
        let lateMarker = "targeted-once-late-marker-c41d"

        try await f.setScore(5)
        await f.sendTargetedEvent()
        try await f.syncNowHolding {
            await f.sendTargetedEvent(lateMarker)
        }
        try await f.waitForEvent(lateMarker, at: f.session)

        let earlyIndices = await f.eventFrameIndices()
        let lateIndices = await f.eventFrameIndices(lateMarker)
        #expect(earlyIndices.count == 1, "batched event must arrive exactly once; frames at \(earlyIndices)")
        #expect(lateIndices.count == 1, "event queued during the batch must arrive exactly once; frames at \(lateIndices)")
    }

    // As above: the "in-batch" events are now queued while the cycle is held before `endSync`
    // and the follow-up cycle sends them; the per-session and ordering claims are unchanged.
    @Test("opcode 107: two sessions with interleaved pre-batch and in-flight events each get their own events once")
    func twoSessionsInterleavedEventsArriveOnceAtTheirOwnSession() async throws {
        let f = try await TargetedOnceFixture.make(encoding: .messagepack)
        let sessionB = SessionID("to-session-b")
        let clientB = ClientID("to-client-b")
        let playerB = PlayerID("to-player-b")
        try await f.joinSecondSession(session: sessionB, client: clientB, player: playerB)

        // A has a per-player change (served by the batch); B has none (served by the flush).
        try await f.setScore(5)
        await f.sendTargetedEvent("evt-a1-pre", to: f.player)
        await f.sendTargetedEvent("evt-b1-pre", to: playerB)
        await f.sendTargetedEvent("evt-a2-pre", to: f.player)
        try await f.syncNowHolding {
            await f.sendTargetedEvent("evt-a3-held", to: f.player)
            await f.sendTargetedEvent("evt-b3-held", to: playerB)
        }
        try await f.waitForEvent("evt-a3-held", at: f.session)
        try await f.waitForEvent("evt-b3-held", at: sessionB)

        let aFrames = await f.transport.frames(for: f.session)
        let bFrames = await f.transport.frames(for: sessionB)
        let aEvents = ["evt-a1-pre", "evt-a2-pre", "evt-a3-held"]
        let bEvents = ["evt-b1-pre", "evt-b3-held"]

        for event in aEvents {
            #expect(frameIndices(containing: event, in: aFrames).count == 1, "\(event) must reach A exactly once")
            #expect(frameIndices(containing: event, in: bFrames).isEmpty, "\(event) must not reach B")
        }
        for event in bEvents {
            #expect(frameIndices(containing: event, in: bFrames).count == 1, "\(event) must reach B exactly once")
            #expect(frameIndices(containing: event, in: aFrames).isEmpty, "\(event) must not reach A")
        }

        let aState = messagePackStateFrameIndices(aFrames)
        #expect(aState.count == 1, "expected one per-player state frame for A; got \(aState)")
        #expect(messagePackStateFrameIndices(bFrames).isEmpty, "B has no state change this cycle")
        if let state = aState.first {
            for event in ["evt-a1-pre", "evt-a2-pre"] {
                if let index = frameIndices(containing: event, in: aFrames).first {
                    #expect(index < state, "\(event) (\(index)) must precede A's state frame (\(state))")
                }
            }
            if let index = frameIndices(containing: "evt-a3-held", in: aFrames).first {
                #expect(index > state, "evt-a3-held (\(index)) is queued after the batch and follows A's state frame (\(state))")
            }
        }
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
