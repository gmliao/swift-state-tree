// Tests/SwiftStateTreeTests/ResolverDeadlineTests.swift
//
// The resolver deadline (#104) and the OnJoin failure it makes routine: a join whose OnJoin
// resolvers throw or time out removes the player it inserted, and an empty land gets its destroy
// timer back. A stuck resolver waits on a gate that ignores cancellation, so it never ends on
// its own: its outcome doesn't depend on timing, only the deadline's length does.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct DeadlineTestState: StateNodeProtocol {
    /// What ran, in order: "join:<player>", "leave:<player>".
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

struct DeadlineResolverOutput: ResolverOutput {
    let value: Int
}

/// Behaviour by player ID: "stuck-<n>" waits on gate n (ignoring cancellation), "sleep-<n>"
/// sleeps until cancelled, "fail-<n>" throws; any other player passes. A client ID starting
/// with "sleep-" sleeps too, whatever the player.
private enum DeadlineBehaviour {
    static func run(_ ctx: ResolverContext) async throws -> DeadlineResolverOutput {
        if ctx.clientID.rawValue.hasPrefix("sleep-") {
            try await safeTaskSleep(for: .seconds(3600))
        }
        let id = ctx.playerID.rawValue
        let key = Int(id.split(separator: "-").last ?? "") ?? 0
        if id.hasPrefix("stuck-") {
            await DeliveryGates.gate(9_400 + key).enterAndWait()
        } else if id.hasPrefix("sleep-") {
            try await safeTaskSleep(for: .seconds(3600))
        } else if id.hasPrefix("fail-") {
            throw ResolverError.dataLoadFailed("fail")
        }
        return DeadlineResolverOutput(value: 0)
    }
}

struct DeadlineJoinResolver: ContextResolver {
    typealias Output = DeadlineResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> DeadlineResolverOutput {
        try await DeadlineBehaviour.run(ctx)
    }
}

/// OnLeave: "leaver-<n>" waits on gate 9500 + n, ignoring cancellation (its OnJoin passes).
struct DeadlineLeaveResolver: ContextResolver {
    typealias Output = DeadlineResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> DeadlineResolverOutput {
        let id = ctx.playerID.rawValue
        if id.hasPrefix("leaver-") {
            await DeliveryGates.gate(9_500 + (Int(id.split(separator: "-").last ?? "") ?? 0)).enterAndWait()
        }
        return DeadlineResolverOutput(value: 0)
    }
}

/// Tickless, OnJoin and OnLeave with resolvers; with `destroyWhenEmpty`, destroyed 1 ms after
/// it empties (only the destroy test: elsewhere a pause would let the land close under it).
private func makeDeadlineDefinition(destroyWhenEmpty: Bool) -> LandDefinition<DeadlineTestState> {
    guard destroyWhenEmpty else {
        return Land("deadline-test", using: DeadlineTestState.self) {
            Rules {
                OnJoin(resolvers: DeadlineJoinResolver.self) { (state: inout DeadlineTestState, ctx: LandContext) in
                    state.log.append("join:\(ctx.playerID.rawValue)")
                }
                OnLeave(resolvers: DeadlineLeaveResolver.self) { (state: inout DeadlineTestState, ctx: LandContext) in
                    state.log.append("leave:\(ctx.playerID.rawValue)")
                }
            }
        }
    }
    return Land("deadline-test", using: DeadlineTestState.self) {
        Rules {
            OnJoin(resolvers: DeadlineJoinResolver.self) { (state: inout DeadlineTestState, ctx: LandContext) in
                state.log.append("join:\(ctx.playerID.rawValue)")
            }
            OnLeave(resolvers: DeadlineLeaveResolver.self) { (state: inout DeadlineTestState, ctx: LandContext) in
                state.log.append("leave:\(ctx.playerID.rawValue)")
            }
        }
        Lifetime {
            DestroyWhenEmpty(after: .milliseconds(1)) { (_: inout DeadlineTestState, _: LandContext) in }
        }
    }
}

/// Records the end of the land's destruction.
private actor DestroyRecorder: LandKeeperTransport {
    private(set) var destroyed = false

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async { destroyed = true }
}

private func makeKeeper(destroyWhenEmpty: Bool = false, transport: (any LandKeeperTransport)? = nil) -> LandKeeper<DeadlineTestState> {
    LandKeeper<DeadlineTestState>(
        definition: makeDeadlineDefinition(destroyWhenEmpty: destroyWhenEmpty),
        initialState: DeadlineTestState(),
        autoStartLoops: false,
        transport: transport
    )
}

/// Runs `body` with a resolver deadline of `deadline` and its own metrics.
private func withDeadline<T: Sendable>(
    _ deadline: Duration,
    metrics: ResolverDeadlineMetrics,
    _ body: () async throws -> T
) async rethrows -> T {
    try await ResolverDeadline.$overrideForTesting.withValue(deadline) {
        try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
            try await body()
        }
    }
}

private func join(_ keeper: LandKeeper<DeadlineTestState>, _ player: String) async throws {
    try await keeper.join(playerID: PlayerID(player), clientID: ClientID("c-\(player)"), sessionID: SessionID("s-\(player)"))
}

private func joinThroughSession(_ keeper: LandKeeper<DeadlineTestState>, _ player: String) async throws {
    _ = try await keeper.join(
        session: PlayerSession(playerID: player),
        clientID: ClientID("c-\(player)"),
        sessionID: SessionID("s-\(player)"),
        services: LandServices()
    )
}

/// The deadline for operations expected to finish: long, so a loaded machine doesn't time them out.
private let generous = Duration.seconds(30)
/// The deadline for operations stuck on purpose.
private let short = Duration.milliseconds(20)

/// Whether `error` is a resolver timeout naming `resolver`.
private func isTimeout(_ error: any Error, naming resolver: String) -> Bool {
    guard case .timedOut(let names, _)? = error as? ResolverExecutionError else { return false }
    return names == [resolver]
}

@Suite("Resolver deadline", .timeLimit(.minutes(1)))
struct ResolverDeadlineTests {
    @Test("An OnJoin resolver stuck past the deadline: the join fails, no player is left, and the keeper takes the next join")
    func stuckOnJoinResolver() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let gate = DeliveryGates.gate(9_401)
        defer { gate.release() }
        await withDeadline(short, metrics: metrics) {
            do {
                try await join(keeper, "stuck-1")
                Issue.record("Expected a resolver timeout")
            } catch {
                #expect(isTimeout(error, naming: "DeadlineJoinResolver"), "\(error)")
            }
        }
        #expect(await keeper.playerCount() == 0, "the inserted player is removed")
        #expect(metrics.snapshot == .init(timeouts: 1, abandoned: 1, onLeaveDropped: 0))

        try await withDeadline(generous, metrics: metrics) { try await join(keeper, "p-1") }
        #expect(await keeper.playerCount() == 1)

        // The abandoned resolver ends: the gauge comes down, and its late result changes nothing.
        gate.release()
        _ = try await withinDeadline("the abandoned resolver ends") { () async -> Void in
            while metrics.snapshot.abandoned != 0 { await Task.yield() }
        }
        #expect(await keeper.playerCount() == 1)
        #expect(await keeper.currentState().log == ["join:p-1"])
    }

    @Test("A timed-out resolver that honours cancellation is cancelled: the abandoned gauge comes down without a release")
    func timedOutResolverIsCancelled() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        _ = await withDeadline(short, metrics: metrics) {
            await #expect(throws: ResolverExecutionError.self) { try await join(keeper, "sleep-2") }
        }
        _ = try await withinDeadline("the cancelled resolver ends") { () async -> Void in
            while metrics.snapshot.abandoned != 0 { await Task.yield() }
        }
        #expect(metrics.snapshot.timeouts == 1)
    }

    @Test("Resolvers that finish within the deadline: the join goes through, nothing is counted")
    func resolverWithinDeadline() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        try await withDeadline(generous, metrics: metrics) {
            try await join(keeper, "p-3")
        }
        #expect(await keeper.playerCount() == 1)
        #expect(metrics.snapshot == .init(timeouts: 0, abandoned: 0, onLeaveDropped: 0))
    }

    @Test("An OnJoin resolver that throws (no deadline): no player is left, and the empty land is still destroyed", arguments: [false, true])
    func throwingOnJoinResolver(throughSession: Bool) async throws {
        let transport = DestroyRecorder()
        let keeper = makeKeeper(destroyWhenEmpty: true, transport: transport)
        try await withDeadline(.zero, metrics: ResolverDeadlineMetrics()) {
            do {
                if throughSession {
                    try await joinThroughSession(keeper, "fail-4")
                } else {
                    try await join(keeper, "fail-4")
                }
                Issue.record("Expected the resolver's error")
            } catch {
                guard case .resolverFailed(let name, _)? = error as? ResolverExecutionError else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(name == "DeadlineJoinResolver")
            }
        }
        #expect(await keeper.playerCount() == 0, "the inserted player is removed")
        // The insert cancelled the destroy timer; the failure reschedules it.
        _ = try await withinDeadline("the empty land is destroyed") { () async -> Void in
            while !(await transport.destroyed) { await Task.yield() }
        }
    }

    @Test("An OnLeave resolver stuck past the deadline: OnLeave is dropped and counted, and a rejoin's OnJoin has no stale OnLeave after it")
    func stuckOnLeaveResolver() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let player = PlayerID("leaver-5"), client = ClientID("c-leaver-5")
        let gate = DeliveryGates.gate(9_505)
        defer { gate.release() }
        try await withDeadline(generous, metrics: metrics) {
            try await keeper.join(playerID: player, clientID: client, sessionID: SessionID("s-leaver-5"))
        }
        #expect(await keeper.currentState().log == ["join:leaver-5"])

        await withDeadline(short, metrics: metrics) {
            do {
                try await keeper.leave(playerID: player, clientID: client, sessionID: SessionID("s-leaver-5"))
                Issue.record("Expected a resolver timeout")
            } catch {
                #expect(isTimeout(error, naming: "DeadlineLeaveResolver"), "\(error)")
            }
        }
        #expect(await keeper.playerCount() == 0)
        #expect(metrics.snapshot == .init(timeouts: 1, abandoned: 1, onLeaveDropped: 1))

        // The rejoin, while the old OnLeave resolver still runs.
        try await withDeadline(generous, metrics: metrics) {
            try await keeper.join(playerID: player, clientID: client, sessionID: SessionID("s-leaver-5b"))
        }
        gate.release()
        _ = try await withinDeadline("the abandoned resolver ends") { () async -> Void in
            while metrics.snapshot.abandoned != 0 { await Task.yield() }
        }
        #expect(await keeper.currentState().log == ["join:leaver-5", "join:leaver-5"], "no OnLeave, late or otherwise")
        #expect(await keeper.playerCount() == 1)
    }

    @Test("Cancelling the caller cancels its resolvers: the join fails at once, no player is left, nothing times out")
    func callerCancellation() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let joining = Task {
            try await withDeadline(generous, metrics: metrics) { try await join(keeper, "sleep-6") }
        }
        // Inserted, then in its OnJoin resolver.
        _ = try await withinDeadline("the join is in its resolver") { () async -> Void in
            while await keeper.playerCount() == 0 { await Task.yield() }
        }
        joining.cancel()
        _ = try await withinDeadline("the cancelled join returns") { () async -> Void in
            _ = await joining.result
        }
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(await keeper.playerCount() == 0)
        // Abandoned while its task ends, which it does at once: it honours cancellation.
        _ = try await withinDeadline("the cancelled group ends") { () async -> Void in
            while metrics.snapshot.abandoned != 0 { await Task.yield() }
        }
        #expect(metrics.snapshot == .init(timeouts: 0, abandoned: 0, onLeaveDropped: 0))
    }

    @Test("Cancelling the caller of a resolver that ignores cancellation returns at once: abandoned, not timed out")
    func callerCancellationWithStuckResolver() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let gate = DeliveryGates.gate(9_408)
        defer { gate.release() }
        let joining = Task {
            try await withDeadline(generous, metrics: metrics) { try await join(keeper, "stuck-8") }
        }
        await gate.waitUntilEntered()
        joining.cancel()
        // Well before the 30 s deadline.
        _ = try await withinDeadline("the cancelled join returns", deadline: .seconds(10)) { () async -> Void in
            _ = await joining.result
        }
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(await keeper.playerCount() == 0)
        #expect(metrics.snapshot == .init(timeouts: 0, abandoned: 1, onLeaveDropped: 0))

        gate.release()
        _ = try await withinDeadline("the abandoned group ends") { () async -> Void in
            while metrics.snapshot.abandoned != 0 { await Task.yield() }
        }
    }

    @Test("A caller cancelled before its resolvers start: the call throws CancellationError, it doesn't hang")
    func callerCancelledBeforeTheRace() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let started = DeliveryGates.gate(9_409)
        let joining = Task {
            // Cancelled before the join (and its race) begins.
            await started.enterAndWait()
            try await withDeadline(generous, metrics: metrics) { try await join(keeper, "p-9") }
        }
        await started.waitUntilEntered()
        joining.cancel()
        started.release()
        // A hang would be a continuation nobody resumes: stop here rather than await it.
        guard try await withinDeadline("the join returns", { () async -> Void in
            _ = await joining.result
        }) != nil else { return }
        await #expect(throws: (any Error).self) { try await joining.value }
        #expect(await keeper.playerCount() == 0)
    }

    @Test("A join that fails after a newer join of the player replaced its entry leaves the newer player alone")
    func failureAfterReplacement() async throws {
        let keeper = makeKeeper()
        let metrics = ResolverDeadlineMetrics()
        let player = PlayerID("p-7")
        // Join A sleeps in its OnJoin resolver (its client ID), after its insert.
        let joinA = Task {
            try await withDeadline(generous, metrics: metrics) {
                try await keeper.join(playerID: player, clientID: ClientID("sleep-7"), sessionID: SessionID("s-7a"))
            }
        }
        _ = try await withinDeadline("join A is in its resolver") { () async -> Void in
            while await keeper.playerCount() == 0 { await Task.yield() }
        }
        // Join B kicks A's entry and inserts its own.
        try await withDeadline(generous, metrics: metrics) {
            try await keeper.join(playerID: player, clientID: ClientID("c-7b"), sessionID: SessionID("s-7b"))
        }
        joinA.cancel()
        await #expect(throws: (any Error).self) { try await joinA.value }
        #expect(await keeper.playerCount() == 1, "B's entry is not A's to remove")
        #expect(await keeper.currentState().log.last == "join:p-7")
    }

    @Test("RESOLVER_TIMEOUT_MS: default 5 s, 0 disables, invalid values give the default; .zero disables the test override")
    func environment() async {
        #expect(ResolverDeadline.parse(environment: [:]) == .milliseconds(5000))
        #expect(ResolverDeadline.parse(environment: ["RESOLVER_TIMEOUT_MS": "250"]) == .milliseconds(250))
        #expect(ResolverDeadline.parse(environment: ["RESOLVER_TIMEOUT_MS": "0"]) == nil)
        #expect(ResolverDeadline.parse(environment: ["RESOLVER_TIMEOUT_MS": "-3"]) == .milliseconds(5000))
        #expect(ResolverDeadline.parse(environment: ["RESOLVER_TIMEOUT_MS": "soon"]) == .milliseconds(5000))
        ResolverDeadline.$overrideForTesting.withValue(.zero) {
            #expect(ResolverDeadline.current == nil)
        }
        ResolverDeadline.$overrideForTesting.withValue(.milliseconds(7)) {
            #expect(ResolverDeadline.current == .milliseconds(7))
        }
    }
}
