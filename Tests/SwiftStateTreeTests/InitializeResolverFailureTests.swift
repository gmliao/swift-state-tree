// Tests/SwiftStateTreeTests/InitializeResolverFailureTests.swift
//
// What a throwing OnInitialize resolver does (#238): with `.failLand`, the default, the land's
// initialization fails as for a timeout (#104); with `.continue`, OnInitialize runs without the
// group's outputs. A timeout fails the initialization either way. A cancellation is exempt only
// while the land is shutting down.

import Foundation
import Testing
@testable import SwiftStateTree

private struct InitFailureTestError: Error {}

/// OnInitialize's resolver. Behaviour by the land ID's mode, "init-failure:<mode>:<n>": "throw"
/// throws, "cancel" throws `CancellationError`, "multiple" throws `multipleResolversFailed`,
/// "throw-late" throws after 20 ms (so a sibling resolver finishes first), "stuck" sleeps until
/// cancelled; any other mode returns 7.
struct InitFailureResolver: ContextResolver {
    typealias Output = DeadlineResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> DeadlineResolverOutput {
        let parts = ctx.landID.split(separator: ":")
        switch parts.count > 1 ? String(parts[1]) : "" {
        case "throw":
            throw InitFailureTestError()
        case "throw-late":
            try await safeTaskSleep(for: .milliseconds(20))
            throw InitFailureTestError()
        case "cancel":
            throw CancellationError()
        case "multiple":
            throw ResolverExecutionError.multipleResolversFailed([
                (name: "A", error: InitFailureTestError()),
                (name: "B", error: InitFailureTestError()),
            ])
        case "stuck":
            while true { try await safeTaskSleep(for: .seconds(60)) }
        default:
            return DeadlineResolverOutput(value: 7)
        }
    }
}

/// A resolver that succeeds at once with 5 (`ctx.initOk`).
struct InitOkResolver: ContextResolver {
    typealias Output = DeadlineResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> DeadlineResolverOutput {
        DeadlineResolverOutput(value: 5)
    }
}

/// OnInitialize logs "init:<output>" or "init:no-output"; OnJoin "join:<p>"; OnFinalize
/// "finalize"; OnDestroyWhenEmpty "destroyWhenEmpty".
private func makeDefinition(_ policy: InitializeResolverFailure?) -> LandDefinition<DeadlineTestState> {
    let body: @Sendable (inout DeadlineTestState, LandContext) throws -> Void = { state, ctx in
        let output: DeadlineResolverOutput? = ctx.initFailure
        state.log.append(output.map { "init:\($0.value)" } ?? "init:no-output")
    }
    let onJoin = OnJoin { (state: inout DeadlineTestState, ctx: LandContext) in
        state.log.append("join:\(ctx.playerID.rawValue)")
    }
    let onFinalize: LifetimeDirective<DeadlineTestState> = OnFinalize { (state: inout DeadlineTestState, _: LandContext) in
        state.log.append("finalize")
    }
    let destroyWhenEmpty: LifetimeDirective<DeadlineTestState> = DestroyWhenEmpty(after: .seconds(3600)) { (state: inout DeadlineTestState, _: LandContext) in
        state.log.append("destroyWhenEmpty")
    }
    guard let policy else {
        return Land("init-failure", using: DeadlineTestState.self) {
            Rules { onJoin }
            Lifetime {
                OnInitialize(resolvers: InitFailureResolver.self, body)
                onFinalize
                destroyWhenEmpty
            }
        }
    }
    return Land("init-failure", using: DeadlineTestState.self) {
        Rules { onJoin }
        Lifetime {
            OnInitialize(resolvers: InitFailureResolver.self, onResolverFailure: policy, body)
            onFinalize
            destroyWhenEmpty
        }
    }
}

private actor DestroyFlag: LandKeeperTransport {
    private(set) var destroyed = false

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async { destroyed = true }
}

/// A keeper for mode `mode`; its initialization runs on the first call, in that call's scope.
private func makeKeeper(mode: String, test: Int, policy: InitializeResolverFailure?, transport: DestroyFlag) -> LandKeeper<DeadlineTestState> {
    LandKeeper<DeadlineTestState>(
        definition: makeDefinition(policy),
        initialState: DeadlineTestState(),
        autoStartLoops: false,
        landID: "init-failure:\(mode):\(test)",
        transport: transport
    )
}

/// Runs `body` with its own resolver metrics and an init deadline of `initDeadline`: the
/// initialization runs in the scope of the first call that waits for it.
private func scoped(
    _ metrics: ResolverDeadlineMetrics,
    initDeadline: Duration = .seconds(30),
    _ body: () async throws -> Void
) async rethrows {
    try await ResolverDeadline.$initOverrideForTesting.withValue(initDeadline) {
        try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
            try await body()
        }
    }
}

private func join(_ keeper: LandKeeper<DeadlineTestState>, _ player: String) async throws {
    try await keeper.join(playerID: PlayerID(player), clientID: ClientID("c-\(player)"), sessionID: SessionID("s-\(player)"))
}

/// The join is denied as retryable (the initialization failed).
private func expectJoinDenied(_ keeper: LandKeeper<DeadlineTestState>, _ player: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await join(keeper, player)
        Issue.record("Expected landShuttingDown", sourceLocation: sourceLocation)
    } catch let error as JoinError {
        if case .landShuttingDown = error {} else { Issue.record("Unexpected join error: \(error)", sourceLocation: sourceLocation) }
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

/// The initialization failed: joins are denied, a leave throws `LandInitializationError`, the
/// land is torn down, and neither OnInitialize nor a destroy handler ran.
private func expectInitializationFailed(
    _ keeper: LandKeeper<DeadlineTestState>,
    _ transport: DestroyFlag,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> LandInitializationError? {
    await expectJoinDenied(keeper, "p-1", sourceLocation: sourceLocation)
    var failure: LandInitializationError?
    do {
        try await keeper.leave(playerID: PlayerID("p-1"), clientID: ClientID("c-p-1"), sessionID: SessionID("s-p-1"))
        Issue.record("Expected LandInitializationError", sourceLocation: sourceLocation)
    } catch let error as LandInitializationError {
        failure = error
    }
    _ = try await withinDeadline("the land is torn down", sourceLocation: sourceLocation) { () async -> Void in
        while !(await transport.destroyed) { await Task.yield() }
    }
    #expect(await keeper.currentState().log == [], "neither OnInitialize nor a destroy handler ran", sourceLocation: sourceLocation)
    return failure
}

@Suite("OnInitialize resolver failure policy (#238)", .timeLimit(.minutes(1)))
struct InitializeResolverFailureTests {
    @Test("A throwing resolver fails the initialization by default, as a timeout does; counted as a failure, not a timeout")
    func throwFailsInitializationByDefault() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics) {
            let keeper = makeKeeper(mode: "throw", test: 1, policy: nil, transport: transport)
            let failure = try await expectInitializationFailed(keeper, transport)
            guard case .resolverFailed(let name, let underlying)? = failure?.underlying as? ResolverExecutionError else {
                Issue.record("Expected resolverFailed, got \(String(describing: failure?.underlying))")
                return
            }
            #expect(name == "InitFailureResolver")
            #expect(underlying is InitFailureTestError)
        }
        #expect(metrics.snapshot.initFailures == 1)
        #expect(metrics.snapshot.initTimeouts == 0)
    }

    @Test("With .continue, OnInitialize runs without the output and the land serves")
    func continueRunsWithoutTheOutput() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics) {
            let keeper = makeKeeper(mode: "throw", test: 2, policy: .continue, transport: transport)
            try await join(keeper, "p-1")
            #expect(await keeper.currentState().log == ["init:no-output", "join:p-1"])
        }
        #expect(metrics.snapshot.initFailures == 0)
        #expect(!(await transport.destroyed))
    }

    @Test("With .continue, OnInitialize gets none of the group's outputs: not the failing resolver's, nor the one that finished first")
    func continueDropsTheWholeGroup() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        let definition = Land("init-failure", using: DeadlineTestState.self) {
            Lifetime {
                OnInitialize(resolvers: (InitOkResolver.self, InitFailureResolver.self), onResolverFailure: .continue) { (state: inout DeadlineTestState, ctx: LandContext) in
                    let ok: DeadlineResolverOutput? = ctx.initOk
                    let failed: DeadlineResolverOutput? = ctx.initFailure
                    state.log.append("ok:\(ok.map { "\($0.value)" } ?? "none") failed:\(failed.map { "\($0.value)" } ?? "none")")
                }
            }
        }
        try await scoped(metrics) {
            let keeper = LandKeeper<DeadlineTestState>(
                definition: definition,
                initialState: DeadlineTestState(),
                autoStartLoops: false,
                landID: "init-failure:throw-late:9",
                transport: transport
            )
            try await join(keeper, "p-1")
            #expect(await keeper.currentState().log == ["ok:none failed:none"])
        }
        #expect(metrics.snapshot.initFailures == 0)
    }

    @Test("A resolver that succeeds: OnInitialize gets its output, under either policy", arguments: [InitializeResolverFailure.failLand, .continue])
    func successGetsTheOutput(policy: InitializeResolverFailure) async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics) {
            let keeper = makeKeeper(mode: "ok", test: policy == .failLand ? 3 : 4, policy: policy, transport: transport)
            try await join(keeper, "p-1")
            #expect(await keeper.currentState().log == ["init:7", "join:p-1"])
        }
        #expect(metrics.snapshot.initFailures == 0)
    }

    @Test("A timeout fails the initialization under .continue too; counted as a timeout, not a failure")
    func timeoutFailsUnderContinue() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics, initDeadline: .milliseconds(20)) {
            let keeper = makeKeeper(mode: "stuck", test: 5, policy: .continue, transport: transport)
            let failure = try await expectInitializationFailed(keeper, transport)
            guard case .timedOut? = failure?.underlying as? ResolverExecutionError else {
                Issue.record("Expected timedOut, got \(String(describing: failure?.underlying))")
                return
            }
        }
        #expect(metrics.snapshot.initTimeouts == 1)
        #expect(metrics.snapshot.initFailures == 0)
    }

    @Test("A resolver's own CancellationError, while the land isn't shutting down, follows .failLand: the initialization fails")
    func cancellationNotShuttingDownFails() async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics) {
            let keeper = makeKeeper(mode: "cancel", test: 6, policy: .failLand, transport: transport)
            _ = try await expectInitializationFailed(keeper, transport)
        }
        #expect(metrics.snapshot.initFailures == 1)
    }

    @Test("multipleResolversFailed follows the policy", arguments: [InitializeResolverFailure.failLand, .continue])
    func multipleFailuresFollowThePolicy(policy: InitializeResolverFailure) async throws {
        let metrics = ResolverDeadlineMetrics(), transport = DestroyFlag()
        try await scoped(metrics) {
            let keeper = makeKeeper(mode: "multiple", test: policy == .failLand ? 7 : 8, policy: policy, transport: transport)
            switch policy {
            case .failLand:
                _ = try await expectInitializationFailed(keeper, transport)
            case .continue:
                try await join(keeper, "p-1")
                #expect(await keeper.currentState().log == ["init:no-output", "join:p-1"])
            }
        }
        #expect(metrics.snapshot.initFailures == (policy == .failLand ? 1 : 0))
    }

    @Test("The decision: .failLand fails unless a cancellation arrives while the land is shutting down; .continue never fails")
    func decision() {
        typealias Keeper = LandKeeper<DeadlineTestState>
        let cancelled = ResolverExecutionError.resolverFailed(name: "R", underlyingError: CancellationError())
        let failed = ResolverExecutionError.resolverFailed(name: "R", underlyingError: InitFailureTestError())
        let allCancelled = ResolverExecutionError.multipleResolversFailed([(name: "A", error: CancellationError()), (name: "B", error: CancellationError())])
        let mixed = ResolverExecutionError.multipleResolversFailed([(name: "A", error: CancellationError()), (name: "B", error: InitFailureTestError())])

        #expect(Keeper.initializeResolverFailureFailsLand(failed, policy: .failLand, shuttingDown: false))
        #expect(Keeper.initializeResolverFailureFailsLand(failed, policy: .failLand, shuttingDown: true))
        #expect(Keeper.initializeResolverFailureFailsLand(cancelled, policy: .failLand, shuttingDown: false))
        #expect(!Keeper.initializeResolverFailureFailsLand(cancelled, policy: .failLand, shuttingDown: true))
        #expect(!Keeper.initializeResolverFailureFailsLand(CancellationError(), policy: .failLand, shuttingDown: true))
        #expect(!Keeper.initializeResolverFailureFailsLand(allCancelled, policy: .failLand, shuttingDown: true))
        #expect(Keeper.initializeResolverFailureFailsLand(mixed, policy: .failLand, shuttingDown: true))
        for error in [failed, cancelled, allCancelled, mixed] as [any Error] {
            for shuttingDown in [false, true] {
                #expect(!Keeper.initializeResolverFailureFailsLand(error, policy: .continue, shuttingDown: shuttingDown))
            }
        }
    }

    @Test("The DSL: .failLand by default, and the choice reaches the definition, for each resolver count")
    func dsl() {
        #expect(makeDefinition(nil).lifetimeHandlers.onInitializeResolverFailure == .failLand)
        #expect(makeDefinition(.continue).lifetimeHandlers.onInitializeResolverFailure == .continue)
        let two = Land("init-failure-two", using: DeadlineTestState.self) {
            Lifetime {
                OnInitialize(resolvers: (InitFailureResolver.self, InitFailureResolver.self)) { (_: inout DeadlineTestState, _: LandContext) in }
            }
        }
        let three = Land("init-failure-three", using: DeadlineTestState.self) {
            Lifetime {
                OnInitialize(resolvers: (InitFailureResolver.self, InitFailureResolver.self, InitFailureResolver.self), onResolverFailure: .continue) { (_: inout DeadlineTestState, _: LandContext) in }
            }
        }
        #expect(two.lifetimeHandlers.onInitializeResolverFailure == .failLand)
        #expect(three.lifetimeHandlers.onInitializeResolverFailure == .continue)
        let none = Land("init-failure-none", using: DeadlineTestState.self) {
            Lifetime { OnInitialize { (_: inout DeadlineTestState, _: LandContext) in } }
        }
        #expect(none.lifetimeHandlers.onInitializeResolverFailure == .failLand)
    }
}
