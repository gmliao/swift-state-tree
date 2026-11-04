// Tests/SwiftStateTreeTests/LandKeeperDebugFreezeTests.swift
//
// LandKeeper.debugFreeze(generation:timeout:): no tick body starts while frozen, in-flight work
// is drained before it returns, tickless inputs are held until debugResume(generation:), the
// drain has a deadline, and a released generation cannot freeze again (#79).

import Foundation
import Testing
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
            Tick(every: .seconds(3600)) { (state: inout DebugFreezeKeeperState, ctx: LandContext) in
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
                (state: inout DebugFreezeKeeperState, action: DebugFreezeSetValueAction, _: LandContext) in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleAction(DebugFreezeGatedAction.self, resolvers: DebugFreezeGatedResolver.self) {
                (state: inout DebugFreezeKeeperState, action: DebugFreezeGatedAction, _: LandContext) in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleAction(DebugFreezeStuckAction.self, resolvers: DebugFreezeStuckResolver.self) {
                (state: inout DebugFreezeKeeperState, action: DebugFreezeStuckAction, _: LandContext) in
                state.value = action.value
                return DebugFreezeAck(ok: true)
            }
            HandleEvent(DebugFreezeBumpEvent.self) {
                (state: inout DebugFreezeKeeperState, event: DebugFreezeBumpEvent, _: LandContext) in
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

/// Keeper transport whose event send waits on a gate, so a tick body can be held in flight.
actor DebugFreezeGatedKeeperTransport: LandKeeperTransport {
    let gate = DebugFreezeGate(open: true)

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        await gate.pass()
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
}

/// Resolver that waits on a shared gate; only `tickless resolver in flight` uses it.
struct DebugFreezeGatedResolver: ContextResolver {
    typealias Output = DebugFreezeGatedResolverOutput
    static let gate = DebugFreezeGate(open: false)

    static func resolve(ctx: ResolverContext) async throws -> DebugFreezeGatedResolverOutput {
        await gate.pass()
        return DebugFreezeGatedResolverOutput(ok: true)
    }
}

/// Resolver that stays stuck until the test opens its gate; only `drainDeadline` uses it.
struct DebugFreezeStuckResolver: ContextResolver {
    typealias Output = DebugFreezeGatedResolverOutput
    static let gate = DebugFreezeGate(open: false)

    static func resolve(ctx: ResolverContext) async throws -> DebugFreezeGatedResolverOutput {
        await gate.pass()
        return DebugFreezeGatedResolverOutput(ok: true)
    }
}

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

@Suite("LandKeeper debug freeze (#79)", .timeLimit(.minutes(1)))
struct LandKeeperDebugFreezeTests {
    let player = PlayerID("p1")
    let client = ClientID("c1")
    let session = SessionID("s1")

    @Test("Freeze waits for a tick already running; no tick body starts while frozen")
    func freezeDrainsRunningTick() async throws {
        let transport = DebugFreezeGatedKeeperTransport()
        let keeper = LandKeeper<DebugFreezeKeeperState>(
            definition: makeTickDefinition(),
            initialState: DebugFreezeKeeperState(),
            autoStartLoops: false,
            transport: transport
        )
        try await keeper.join(playerID: player, clientID: client, sessionID: session)

        // Hold the tick inside its output flush.
        await transport.gate.close()
        let tick = Task { await keeper.stepTickOnce() }
        #expect(await eventually { await transport.gate.waitingCount == 1 })

        let freezeDone = DoneFlag()
        let freeze = Task {
            let drained = await keeper.debugFreeze(generation: 1, timeout: .seconds(10))
            await freezeDone.set()
            return drained
        }
        await settleScheduler()
        #expect(await freezeDone.isDone == false, "freeze returned while a tick was still running")

        await transport.gate.open()
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
            let drained = await keeper.debugFreeze(generation: 1, timeout: .seconds(10))
            await freezeDone.set()
            return drained
        }
        await settleScheduler()
        #expect(await freezeDone.isDone == false, "freeze returned while a resolver was in flight")

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

        let start = ContinuousClock.now
        #expect(await keeper.debugFreeze(generation: 1, timeout: .milliseconds(100)) == false)
        #expect(ContinuousClock.now - start < .seconds(2), "drain ignored its deadline")
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
}
