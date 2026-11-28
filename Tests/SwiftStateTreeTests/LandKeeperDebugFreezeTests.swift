// Tests/SwiftStateTreeTests/LandKeeperDebugFreezeTests.swift
//
// LandKeeper.debugFreeze(generation:timeout:): no tick body starts while frozen, in-flight work
// is drained before it returns, tickless inputs are held until debugResume(generation:), the
// drain has a deadline, and a released generation cannot freeze again (#79).

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

// MARK: - Test lands

@StateNodeBuilder
struct DebugFreezeKeeperState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    @Sync(.broadcast)
    var value: String = ""

    @Sync(.broadcast)
    var events: Int = 0

    public init() {}
}

@Payload
struct DebugFreezeTickEvent: ServerEventPayload {
    let tick: Int
}

@Payload
struct DebugFreezeSetValueAction: ActionPayload {
    typealias Response = DebugFreezeAck
    let value: String
}

@Payload
struct DebugFreezeGatedAction: ActionPayload {
    typealias Response = DebugFreezeAck
    let value: String
}

@Payload
struct DebugFreezeStuckAction: ActionPayload {
    typealias Response = DebugFreezeAck
    let value: String
}

@Payload
struct DebugFreezeAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct DebugFreezeBumpEvent: ClientEventPayload {
    let amount: Int
}

/// Tick land with manual stepping: the tick emits a server event, so the tick body awaits the
/// keeper transport while flushing outputs.
private func makeTickDefinition() -> LandDefinition<DebugFreezeKeeperState> {
    Land("debug-freeze-tick", using: DebugFreezeKeeperState.self) {
        ServerEvents {
            Register(DebugFreezeTickEvent.self)
        }
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitEvent(DebugFreezeTickEvent(tick: state.ticks), to: .all)
            }
        }
    }
}

/// Tickless land: actions and client events apply immediately.
private func makeTicklessDefinition() -> LandDefinition<DebugFreezeKeeperState> {
    Land("debug-freeze-tickless", using: DebugFreezeKeeperState.self) {
        ClientEvents {
            Register(DebugFreezeBumpEvent.self)
        }
        Rules {
            HandleAction(DebugFreezeSetValueAction.self) {
                state, action, _ in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleAction(DebugFreezeGatedAction.self, resolvers: { _, _, _ in DebugFreezeGatedResolver() }) {
                state, action, _, _ in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleAction(DebugFreezeStuckAction.self, resolvers: { _, _, _ in DebugFreezeStuckResolver() }) {
                state, action, _, _ in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleEvent(DebugFreezeBumpEvent.self) {
                state, event, _ in
                state.events += event.amount
            }
        }
    }
}

// MARK: - Gates

/// A gate that callers wait on until it is opened.
actor DebugFreezeGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitingCount = 0

    init(open: Bool) { isOpen = open }

    func pass() async {
        guard !isOpen else { return }
        waitingCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func close() { isOpen = false }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Resolver that waits on a shared gate; only `tickless resolver in flight` uses it.
@PlainData
struct DebugFreezeGatedResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = DebugFreezeGatedResolverOutput
    static let gate = DebugFreezeGate(open: false)

    func resolve(_ deps: NoServices) async throws -> DebugFreezeGatedResolverOutput {
        await Self.gate.pass()
        return DebugFreezeGatedResolverOutput(ok: true)
    }
}

/// Resolver that stays stuck until the test opens its gate; only `drainDeadline` uses it.
@PlainData
struct DebugFreezeStuckResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = DebugFreezeGatedResolverOutput
    static let gate = DebugFreezeGate(open: false)

    func resolve(_ deps: NoServices) async throws -> DebugFreezeGatedResolverOutput {
        await Self.gate.pass()
        return DebugFreezeGatedResolverOutput(ok: true)
    }
}

@PlainData
struct DebugFreezeGatedResolverOutput: ResolverOutput {
    let ok: Bool
}

/// Completion flag for a task started in the background.
private actor DoneFlag {
    private(set) var isDone = false
    func set() { isDone = true }
}

/// Wait (bounded) until `condition` holds.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Let other tasks run for a while; used to show that something did not happen.
private func settleScheduler() async {
    for _ in 0..<20 {
        await Task.yield()
    }
    try? await Task.sleep(for: .milliseconds(20))
}

private func envelope<A: ActionPayload>(_ action: A) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(action))
}

// MARK: - Tests

@Suite("LandKeeper debug freeze (#79)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct LandKeeperDebugFreezeTests {
    let player = PlayerID("p1")
    let client = ClientID("c1")
    let session = SessionID("s1")

    @Test("Freeze waits for a tick already running; no tick body starts while frozen")
    func freezeDrainsRunningTick() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTickDefinition(),
            initialState: DebugFreezeKeeperState(),
            autoStartLoops: false
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        // Hold the tick turn at its record: the turn has run, its in-flight count hasn't ended.
        let record = WatermarkGate()
        await keeper.installHolds { point in
            if point == .turnRecord { await record.enterAndWait() }
        }
        let tick = Task { await keeper.stepTickOnce() }
        guard await record.waitUntilEntered() else { return }

        let freezeDone = DoneFlag()
        let freeze = Task {
            let drained = await keeper.debugFreeze(generation: 1, timeout: freezeWithoutDeadline)
            await freezeDone.set()
            return drained
        }
        // The freeze is waiting on the held tick: it registered its waiter with the work in flight.
        await keeper.waitUntilFreezeWaitsForTesting()
        #expect(await freezeDone.isDone == false, "freeze returned while a tick was still running")
        #expect(await keeper.debugInFlightWorkForTesting() == 1)

        await keeper.installHolds(nil)
        record.release()
        #expect(await freeze.value)
        await tick.value
        #expect(await keeper.currentState().ticks == 1)
        #expect(await keeper.isDebugFrozen())

        // Frozen: a tick request does not run the tick body.
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 1)

        await keeper.debugResume(generation: 1)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 2)
    }

    @Test("Tickless: an action sent while frozen is held and applied after resume")
    func ticklessActionHeldUntilResume() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        let action = Task { [player, client, session] in
            try await keeper.handleActionEnvelope(
                envelope(DebugFreezeSetValueAction(value: "after-resume")),
                playerID: player, clientID: client, sessionID: session
            )
        }
        await settleScheduler()
        #expect(await keeper.currentState().value == "", "action applied while frozen")

        await keeper.debugResume(generation: 1)
        _ = try await action.value
        #expect(await keeper.currentState().value == "after-resume")
    }

    @Test("Tickless: a resolver in flight at freeze time completes before freeze returns")
    func ticklessResolverDrained() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        await DebugFreezeGatedResolver.gate.close()
        let action = Task { [player, client, session] in
            try await keeper.handleActionEnvelope(
                envelope(DebugFreezeGatedAction(value: "resolved")),
                playerID: player, clientID: client, sessionID: session
            )
        }
        #expect(await eventually { await DebugFreezeGatedResolver.gate.waitingCount == 1 })

        let freezeDone = DoneFlag()
        let freeze = Task {
            let drained = await keeper.debugFreeze(generation: 1, timeout: freezeWithoutDeadline)
            await freezeDone.set()
            return drained
        }
        // The freeze is waiting on the held tick: it registered its waiter with the work in flight.
        await keeper.waitUntilFreezeWaitsForTesting()
        #expect(await freezeDone.isDone == false, "freeze returned while a resolver was in flight")
        #expect(await keeper.debugInFlightWorkForTesting() == 1)

        await DebugFreezeGatedResolver.gate.open()
        #expect(await freeze.value)
        #expect(await keeper.currentState().value == "resolved", "drained action not applied before freeze returned")
        _ = try await action.value
        await keeper.debugResume(generation: 1)
    }

    @Test("Tickless: a client event sent while frozen is held and applied after resume")
    func ticklessClientEventHeldUntilResume() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        let event = Task { [player, client, session] in
            try await keeper.handleClientEvent(
                AnyClientEvent(DebugFreezeBumpEvent(amount: 3)),
                playerID: player, clientID: client, sessionID: session
            )
        }
        await settleScheduler()
        #expect(await keeper.currentState().events == 0, "client event applied while frozen")

        await keeper.debugResume(generation: 1)
        try await event.value
        #expect(await eventually { await keeper.currentState().events == 3 })
    }

    @Test("Tickless: a client event that waits out a freeze while the land closes is refused, not applied")
    func ticklessClientEventRefusedWhenLandClosesDuringFreeze() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        let signals = KeeperProbeSignals()
        await keeper.setInTurnProbeForTesting(signals.probe)
        let event = Task { [player, client, session] in
            try await keeper.handleClientEvent(
                AnyClientEvent(DebugFreezeBumpEvent(amount: 3)),
                playerID: player, clientID: client, sessionID: session
            )
        }
        // Past the driver's check and held at the freeze: the hold's probe, not a timing guess,
        // so the driver's own check can't be the one that refuses it.
        #expect(await signals.wait(for: "input-held-frozen"))
        // The land closes while the event waits; the intake's own segment must see it.
        await keeper.markDrainingForTesting(cause: .forceShutdown)
        await keeper.debugResume(generation: 1)
        await #expect(throws: LandInputRejection.landClosed) { try await event.value }
        await settleScheduler()
        #expect(await keeper.currentState().events == 0, "applied after the land closed")
    }

    @Test("The drain has a deadline: a stuck resolver makes freeze return false, and resume releases")
    func drainDeadline() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        let gate = DebugFreezeStuckResolver.gate
        let action = Task { [player, client, session] in
            try await keeper.handleActionEnvelope(
                envelope(DebugFreezeStuckAction(value: "late")),
                playerID: player, clientID: client, sessionID: session
            )
        }
        #expect(await eventually { await gate.waitingCount == 1 })

        // The resolver stays held until after the drain, so only the 100 ms timeout can end it.
        // Bounded on the drain's end event, not on elapsed time (#978): a drain that ignored its
        // deadline never ends, which the hang bound reports.
        let ended = EventLog()
        let drain = Task {
            defer { ended.append("ended") }
            return await keeper.debugFreeze(generation: 1, timeout: .milliseconds(100))
        }
        let drainEnded = await ended.waitFor("ended")
        if !drainEnded { await gate.open() }
        try #require(drainEnded, "drain ignored its deadline: it waited on the held resolver")
        #expect(await drain.value == false)
        #expect(await keeper.isDebugFrozen(), "a missed deadline keeps the freeze until it is released")

        await keeper.debugResume(generation: 1)
        #expect(await keeper.isDebugFrozen() == false)

        await gate.open()
        _ = try await action.value
        #expect(await keeper.currentState().value == "late")
        #expect(await keeper.isDebugFrozen() == false, "late drain re-froze the land")
    }

    @Test("A released generation cannot freeze again; a stale resume does not release a newer freeze")
    func generations() async throws {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(1)))
        await keeper.debugResume(generation: 1)

        // A late freeze of generation 1 (e.g. an aborted settle) is refused.
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(1)) == false)
        #expect(await keeper.isDebugFrozen() == false)

        #expect(await keeper.debugFreeze(generation: 2, timeout: .seconds(1)))
        await keeper.debugResume(generation: 1)
        #expect(await keeper.isDebugFrozen(), "a stale resume released a newer freeze")
        await keeper.debugResume(generation: 2)
        #expect(await keeper.isDebugFrozen() == false)
    }

    @Test("The freeze-registration watcher's bound: with no caller registering, it answers false instead of hanging (Review on #966)")
    func freezeRegistrationWatcherExpires() async {
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTicklessDefinition(),
            initialState: DebugFreezeKeeperState()
        )
        await keeper.awaitInitialization()
        // No freeze caller exists, so only the bound can end this wait: the false path.
        #expect(await keeper.waitUntilFreezeRegistrationsForTesting(1, within: .milliseconds(20)) == false)
        // A count already reached still answers true at once after an expiry.
        #expect(await keeper.waitUntilFreezeRegistrationsForTesting(0, within: .milliseconds(20)))
    }
}
