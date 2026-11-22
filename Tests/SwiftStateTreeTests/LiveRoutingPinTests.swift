// Tests/SwiftStateTreeTests/LiveRoutingPinTests.swift
//
// #546 L2d-2: how a live keeper routes its inputs, ticks and initialization, pinned on a keeper
// with no transport (the kind L2d-2 moves onto turns), and what happens to an output made before
// the transport is attached (§3.5's pin).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixture

@StateNodeBuilder
struct RoutingPinState: StateNodeProtocol {
    @Sync(.broadcast) var log: [String] = []
    @Sync(.broadcast) var ticks: Int = 0
    init() {}
}

@Payload
struct RoutingPinAction: ActionPayload {
    typealias Response = RoutingPinAck
    let tag: String
}

@Payload
struct RoutingPinAck: ResponsePayload {
    let count: Int
}

@Payload
struct RoutingPinClientEvent: ClientEventPayload {
    let tag: String
}

@Payload
struct RoutingPinInput: ServerInputPayload {
    let tag: String
}

@Payload
struct RoutingPinEvent: ServerEventPayload {
    let entry: String
}

/// Every input kind logs, emits one event and requests a sync, so each route has outputs to take.
private func logAndEmit(_ entry: String, _ state: inout RoutingPinState, _ ctx: LandContext) {
    state.log.append(entry)
    ctx.emitEvent(RoutingPinEvent(entry: entry), to: .all)
    ctx.requestSyncNow()
}

func makeRoutingPinLand(tick: Bool) -> LandDefinition<RoutingPinState> {
    let rules = Rules {
        OnJoin { (state: inout RoutingPinState, ctx: LandContext) in logAndEmit("join:\(ctx.playerID.rawValue)", &state, ctx) }
        OnLeave { (state: inout RoutingPinState, ctx: LandContext) in logAndEmit("leave:\(ctx.playerID.rawValue)", &state, ctx) }
        HandleAction(RoutingPinAction.self) { (state: inout RoutingPinState, action: RoutingPinAction, ctx: LandContext) in
            logAndEmit("action:\(action.tag)", &state, ctx)
            return RoutingPinAck(count: state.log.count)
        }
        HandleEvent(RoutingPinClientEvent.self) { (state: inout RoutingPinState, event: RoutingPinClientEvent, ctx: LandContext) in
            logAndEmit("event:\(event.tag)", &state, ctx)
        }
        HandleServerInput(RoutingPinInput.self) { (state: inout RoutingPinState, input: RoutingPinInput, ctx: LandContext) in
            logAndEmit("input:\(input.tag)", &state, ctx)
        }
    }
    if tick {
        return Land("routing-pin-tick", using: RoutingPinState.self) {
            ClientEvents { Register(RoutingPinClientEvent.self) }
            ServerEvents { Register(RoutingPinEvent.self) }
            rules
            Lifetime {
                OnInitialize { (state: inout RoutingPinState, ctx: LandContext) in logAndEmit("initialize", &state, ctx) }
                // Hourly and stepped by hand: no real tick runs during a test.
                Tick(every: .seconds(3600)) { (state: inout RoutingPinState, ctx: LandContext) in
                    state.ticks += 1
                    ctx.emitEvent(RoutingPinEvent(entry: "tick:\(state.ticks)"), to: .all)
                }
            }
        }
    }
    return Land("routing-pin-tickless", using: RoutingPinState.self) {
        ClientEvents { Register(RoutingPinClientEvent.self) }
        ServerEvents { Register(RoutingPinEvent.self) }
        rules
        Lifetime {
            OnInitialize { (state: inout RoutingPinState, ctx: LandContext) in logAndEmit("initialize", &state, ctx) }
        }
    }
}

/// A live keeper with no transport. Recording on, so its records can be read; loops off, so every
/// step is the test's.
private func makePortlessKeeper(tick: Bool) async -> LandKeeper<RoutingPinState> {
    let definition = makeRoutingPinLand(tick: tick)
    let keeper = LandKeeper<RoutingPinState>(
        definition: definition,
        initialState: RoutingPinState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: "\(definition.id):\(UUID().uuidString)"
    )
    await keeper.awaitInitialization()
    return keeper
}

/// The probe labels a keeper fires (`setInTurnProbeForTesting`).
private final class RoutingPinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    func append(_ label: String) { lock.withLock { labels.append(label) } }
    var turnsBegun: Int { lock.withLock { labels.filter { $0 == "turn-begin" }.count } }
    var all: [String] { lock.withLock { labels } }
}

/// Opts in, and records the events each turn hands it (by their `entry`) and its sync phases.
final class RoutingPinPort: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var phases = 0
    var delivered: [String] { lock.withLock { entries } }
    var syncPhases: Int { lock.withLock { phases } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        lock.withLock { entries.append("legacy:\(Self.entry(of: event))") }
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        lock.withLock {
            entries.append(contentsOf: events.map { Self.entry(of: $0.event) })
            if includeSync { phases += 1 }
        }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }

    static func entry(of event: AnyServerEvent) -> String {
        let data = (try? JSONEncoder().encode(event.payload)) ?? Data()
        return (try? JSONDecoder().decode(RoutingPinEvent.self, from: data))?.entry ?? event.type
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

private func envelope(_ tag: String) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: RoutingPinAction.self), payload: AnyCodable(RoutingPinAction(tag: tag)))
}

private func frames(_ keeper: LandKeeper<RoutingPinState>) async throws -> [ReevaluationTickFrame] {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    return await recorder.getAllFrames()
}

// MARK: - Routing with no port

@Suite("L2d-2 routing pin: a live keeper with no port", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct LiveRoutingPinTests {
    @Test("A portless live keeper reports no in-turn sync and records no sync stream", arguments: [false, true])
    func portlessAnswers(tick: Bool) async throws {
        let keeper = await makePortlessKeeper(tick: tick)
        #expect(await keeper.isUsingInTurnSync() == false)
        #expect(await keeper.recordsSyncStream == false)
        #expect(await keeper.syncStreamCounterForTesting() == 0)
    }

    @Test("Tickless, no port: join, action, client event, server input and leave each run in an input turn")
    func ticklessInputsAreTurns() async throws {
        let keeper = await makePortlessKeeper(tick: false)
        let probe = RoutingPinProbe()
        await keeper.setInTurnProbeForTesting(probe.append)

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(envelope("a"), playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.handleClientEvent(AnyClientEvent(RoutingPinClientEvent(tag: "e")), playerID: p1, clientID: c1, sessionID: s1)
        guard case .accepted = await keeper.submitServerInput(RoutingPinInput(tag: "i")) else {
            Issue.record("the server input was refused")
            return
        }
        // The server input's caller doesn't wait for its turn: its in-flight count does.
        await keeper.waitForInFlightWorkForTesting()
        try await keeper.leave(playerID: p1, clientID: c1)

        #expect(probe.turnsBegun == 5, "one input turn per input")
        #expect(await keeper.currentState().log == ["initialize", "join:p1", "action:a", "event:e", "input:i", "leave:p1"])
        #expect(await keeper.emittedEventTicksForTesting() == [])
        let syncRequestTicks = await keeper.syncRequestTicksForTesting()
        #expect(syncRequestTicks == [], "every turn took its request, OnInitialize's too")
    }

    @Test("Tickless, no port: the forced shutdown is applied by an input turn")
    func ticklessForcedShutdownIsATurn() async throws {
        let keeper = await makePortlessKeeper(tick: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let probe = RoutingPinProbe()
        await keeper.setInTurnProbeForTesting(probe.append)
        await keeper.forceShutdown()
        #expect(probe.all.contains("shutdown-queued"))
        #expect(probe.turnsBegun == 1, "the shutdown's input turn")
    }

    @Test("Tick land, no port: a stepped tick is a tick turn whose events and sync request are taken and recorded")
    func tickIsATurn() async throws {
        let keeper = await makePortlessKeeper(tick: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let probe = RoutingPinProbe()
        await keeper.setInTurnProbeForTesting(probe.append)
        await keeper.stepTickOnce()
        #expect(probe.all.first == "turn-begin", "a tick turn")
        #expect(probe.all.contains("turn-end"))
        #expect(await keeper.currentState().ticks == 1)
        #expect(await keeper.emittedEventTicksForTesting() == [])
        let syncRequestTicks = await keeper.syncRequestTicksForTesting()
        #expect(syncRequestTicks == [], "every turn took its request, OnInitialize's too")

        let frame = try #require(try await frames(keeper).first { $0.tickId == 0 })
        #expect(frame.serverEvents.map { $0.sequence }.count == 2, "OnJoin's event and the tick's")
        #expect(frame.lifecycleEvents.map(\.kind).contains("join"))
        #expect(frame.sequenceBeforeInputs != nil)
        #expect(frame.sequenceBeforeTickHandler != nil)
    }

    @Test("No port: a failure noted outside a turn ends the land at the next turn's apply step (#704)", arguments: [false, true])
    func notedFailureEndsPortlessTurn(tick: Bool) async throws {
        let keeper = await makePortlessKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        if tick { await keeper.stepTickOnce() }
        let noted = LandFailure(kind: .eventEncode, detail: "noted outside a turn", position: LandFailurePosition(stage: .eventFlush))
        keeper.notePendingFailure(noted)
        // A turn with no port skips its output step; its apply step still reads the mailbox.
        if tick {
            await keeper.stepTickOnce()
            #expect(await keeper.currentState().ticks == 1, "the tick handler of the failed turn never ran")
        } else {
            _ = try? await keeper.handleActionEnvelope(envelope("a"), playerID: p1, clientID: c1, sessionID: s1)
        }
        #expect(keeper.failure?.kind == noted.kind)
        #expect(keeper.failure?.detail == noted.detail)
    }

    @Test("No port: a sync loop iteration sets no due sync and runs no turn", arguments: [false, true])
    func syncLoopWithoutPort(tick: Bool) async throws {
        let keeper = await makePortlessKeeper(tick: tick)
        let probe = RoutingPinProbe()
        await keeper.setInTurnProbeForTesting(probe.append)
        await keeper.runSyncLoopIterationForTesting()
        #expect(await keeper.inTurnSyncDueForTesting == false)
        #expect(probe.turnsBegun == 0)
    }
}

// MARK: - Outputs made before the attach (§3.5)

/// The keeper-level twin of `LandManager`'s `.wiring` hold, which holds exactly the
/// `setTransport` call (`LandManager.swift:707–708`): initialize and one step with no port, then
/// the attach.
@Suite("L2d-2 pin: outputs made before the attach", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct PreAttachOutputPinTests {
    @Test("Tickless: OnInitialize's event and the input before the attach are recorded and never delivered")
    func ticklessPreAttach() async throws {
        let keeper = await makePortlessKeeper(tick: false)
        #expect(await keeper.emittedEventTicksForTesting() == [], "the initialize turn took its event")

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        let port = RoutingPinPort()
        await keeper.setTransport(port)
        _ = try await keeper.handleActionEnvelope(envelope("after"), playerID: p1, clientID: c1, sessionID: s1)

        #expect(port.delivered == ["action:after"])
        #expect(await keeper.emittedEventTicksForTesting() == [])

        let all = try await frames(keeper)
        let frame0 = try #require(all.first { $0.tickId == 0 })
        let initialize = try #require(frame0.initialize)
        #expect(initialize.serverEvents.map(\.typeIdentifier) == ["RoutingPin"])
        let passes = all.flatMap(\.passes)
        #expect(passes.count == 2, "the join under the hold, then the action")
        #expect(passes.first.map { $0.sequenceBefore > initialize.sequence } == true)
    }

    @Test("Tick land: OnInitialize and tick 0 share frame 0; the tick before the attach delivers nothing")
    func tickPreAttach() async throws {
        let keeper = await makePortlessKeeper(tick: true)
        #expect(await keeper.emittedEventTicksForTesting() == [], "the initialize turn took its event")
        await keeper.stepTickOnce()
        #expect(await keeper.emittedEventTicksForTesting() == [])

        let port = RoutingPinPort()
        await keeper.setTransport(port)
        await keeper.stepTickOnce()
        #expect(port.delivered == ["tick:2"])

        let frame0 = try #require(try await frames(keeper).first { $0.tickId == 0 })
        #expect(frame0.lifecycleEvents.map(\.kind) == ["initialize"])
        let initialize = try #require(frame0.initialize)
        #expect(initialize.serverEvents.count == 1)
        #expect(frame0.serverEvents.count == 1, "tick 0's event")
        #expect(frame0.serverEvents.allSatisfy { $0.sequence > initialize.sequence })
    }
}
