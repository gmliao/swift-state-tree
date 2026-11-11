// Tests/SwiftStateTreeTests/ActionJobTests.swift
//
// An action with resolvers is a job (tick lands here; tickless ones in TicklessActionJobTests): `submitAction` registers it and returns
// without waiting for the resolvers, the completion delivers the result in a keeper turn, and
// the outcome waits in a slot until `awaitActionResult` reads it. A leave cancels the jobs its
// entry's ticket names, and the drain cancels all of them.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ActionJobTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

@Payload
struct ActionJobGatedAction: ActionPayload {
    typealias Response = ActionJobAck
    /// Also the key of the action's resolver gate (`ActionJobGates`).
    let amount: Int
}

@Payload
struct ActionJobPlainAction: ActionPayload {
    typealias Response = ActionJobAck
    let amount: Int
}

@Payload
struct ActionJobAck: ResponsePayload {
    let ok: Bool
}

struct ActionJobResolverOutput: ResolverOutput {
    let value: Int
}

/// One gate per action amount: resolvers are static, and parallel tests must not share a gate.
/// Amounts come only from `freshKey()`, never a literal.
enum ActionJobGates {
    private static let keys = KeyedGates(firstKey: 1_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> WatermarkGate { keys.gate(key, sourceLocation: sourceLocation) }
}

struct ActionJobGatedResolver: ContextResolver {
    typealias Output = ActionJobResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> ActionJobResolverOutput {
        let amount = (ctx.actionPayload as? ActionJobGatedAction)?.amount ?? -1
        // Ignores cancellation, like a resolver blocked in a call that doesn't check it.
        await ActionJobGates.gate(amount).enterAndWait()
        return ActionJobResolverOutput(value: amount)
    }
}

private func makeDefinition(tick: Bool) -> LandDefinition<ActionJobTestState> {
    if tick {
        return Land("action-job-test", using: ActionJobTestState.self) {
            Rules {
                HandleAction(ActionJobGatedAction.self, resolvers: ActionJobGatedResolver.self) {
                    (state: inout ActionJobTestState, action: ActionJobGatedAction, _: LandContext) in
                    state.total += action.amount
                    return ActionJobAck(ok: true)
                }
                HandleAction(ActionJobPlainAction.self) {
                    (state: inout ActionJobTestState, action: ActionJobPlainAction, _: LandContext) in
                    state.total += action.amount
                    return ActionJobAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout ActionJobTestState, _: LandContext) in }
            }
        }
    }
    return Land("action-job-test", using: ActionJobTestState.self) {
        Rules {
            HandleAction(ActionJobGatedAction.self, resolvers: ActionJobGatedResolver.self) {
                (state: inout ActionJobTestState, action: ActionJobGatedAction, _: LandContext) in
                state.total += action.amount
                return ActionJobAck(ok: true)
            }
        }
    }
}

private func makeKeeper(tick: Bool = true, recording: Bool = false) async -> LandKeeper<ActionJobTestState> {
    let keeper = LandKeeper<ActionJobTestState>(
        definition: makeDefinition(tick: tick),
        initialState: ActionJobTestState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false
    )
    await keeper.setLandID("action-job-test:local")
    return keeper
}

private func gated(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: ActionJobGatedAction.self),
        payload: AnyCodable(ActionJobGatedAction(amount: amount))
    )
}

private func plain(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: ActionJobPlainAction.self),
        payload: AnyCodable(ActionJobPlainAction(amount: amount))
    )
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

/// Submits a gated action and expects it to be pending; returns its sequence.
private func submitPending(
    _ keeper: LandKeeper<ActionJobTestState>,
    _ amount: Int,
    player: PlayerID = p1,
    client: ClientID = c1,
    session: SessionID = s1,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Int64 {
    let submission = try await keeper.submitAction(gated(amount), playerID: player, clientID: client, sessionID: session)
    guard case .pending(let sequence) = submission else {
        Issue.record("Expected a pending job, got \(submission)", sourceLocation: sourceLocation)
        return -1
    }
    return sequence
}

private func expectRejection(
    _ expected: LandInputRejection,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> AnyCodable
) async throws {
    let result = try await withinDeadline("awaiting the rejection", sourceLocation: sourceLocation) {
        await outcome(of: body)
    }
    switch result {
    case .none:
        return
    case .success(let value)?:
        Issue.record("Expected \(expected), got \(value.base)", sourceLocation: sourceLocation)
    case .failure(let error)?:
        #expect(error as? LandInputRejection == expected, "got \(error)", sourceLocation: sourceLocation)
    }
}

private func outcome(of body: () async throws -> AnyCodable) async -> Result<AnyCodable, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// The keeper's running jobs and unread slots, as `[jobs, slots]`.
private func counts(_ keeper: LandKeeper<ActionJobTestState>) async -> [Int] {
    let counts = await keeper.actionJobCountsForTesting()
    return [counts.jobs, counts.slots]
}

/// Waits until the keeper's jobs left its table, within a deadline: a broken release fails the
/// test instead of hanging the run.
private func settle(_ keeper: LandKeeper<ActionJobTestState>, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    _ = try await withinDeadline("the action jobs settle", sourceLocation: sourceLocation) {
        await keeper.waitForActionJobsForTesting()
    }
}

/// Holds every job's completion at `.actionComplete` until `gate` is released; `gate` reports
/// the first arrival.
private func holdCompletions(_ keeper: LandKeeper<ActionJobTestState>) async -> WatermarkGate {
    let gate = WatermarkGate()
    await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.actionComplete) { await gate.enterAndWait() })
    return gate
}

private func expectCancellation(
    _ result: Result<AnyCodable, any Error>?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(let value)?:
        Issue.record("Expected the cancellation, got \(value.base)", sourceLocation: sourceLocation)
    case .failure(let error)?:
        #expect(error is CancellationError, "got \(error)", sourceLocation: sourceLocation)
    case nil:
        break
    }
}

@Suite("Action jobs: resolvers off the caller's wait", .timeLimit(.minutes(1)))
struct ActionJobTests {
    @Test("A tick land's action with resolvers is submitted without waiting for them")
    func submitReturnsBeforeResolvers() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        // Returns while the resolver holds: its gate is never released before this line.
        let sequence = try await submitPending(keeper, amount)
        await ActionJobGates.gate(amount).waitUntilEntered()
        #expect(await counts(keeper) == [1, 1])

        ActionJobGates.gate(amount).release()
        let response = try await keeper.awaitActionResult(sequence: sequence)
        #expect(response.base is Void)
        #expect(await counts(keeper) == [0, 0])
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == amount)
    }

    @Test("A reader that arrives after the completion finds the outcome in the slot")
    func lateReaderFindsOutcome() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        ActionJobGates.gate(amount).release()
        try await settle(keeper)
        // Completed and delivered; nobody has read it yet.
        #expect(await counts(keeper) == [0, 1])
        let response = try await keeper.awaitActionResult(sequence: sequence)
        #expect(response.base is Void)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("A late reader of a rejected job gets the rejection, not an empty response")
    func lateReaderFindsRejection() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        await ActionJobGates.gate(amount).waitUntilEntered()
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        ActionJobGates.gate(amount).release()
        try await settle(keeper)
        try await expectRejection(.senderSuperseded) { try await keeper.awaitActionResult(sequence: sequence) }
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("A leave rejects its entry's jobs at once; another player's and a newer entry's jobs go on")
    func leaveCancelsOnlyItsEntrysJobs() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let old = ActionJobGates.freshKey(), other = ActionJobGates.freshKey(), newer = ActionJobGates.freshKey()
        let oldSequence = try await submitPending(keeper, old)
        let otherSequence = try await submitPending(keeper, other, player: p2, client: c2, session: s2)
        await ActionJobGates.gate(old).waitUntilEntered()

        // Same player, client and session again: only the entry's generation tells them apart.
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let newerSequence = try await submitPending(keeper, newer)

        // Rejected while its resolver still holds (its gate is released only at the end).
        try await expectRejection(.senderSuperseded) { try await keeper.awaitActionResult(sequence: oldSequence) }

        ActionJobGates.gate(other).release()
        ActionJobGates.gate(newer).release()
        #expect(try await keeper.awaitActionResult(sequence: otherSequence).base is Void)
        #expect(try await keeper.awaitActionResult(sequence: newerSequence).base is Void)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == other + newer)

        ActionJobGates.gate(old).release()
        try await settle(keeper)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("The drain rejects every pending job with landClosed, while their resolvers still hold")
    func drainCancelsAllJobs() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        await ActionJobGates.gate(amount).waitUntilEntered()

        let shutdown = Task { await keeper.forceShutdown() }
        try await expectRejection(.landClosed) { try await keeper.awaitActionResult(sequence: sequence) }
        await shutdown.value

        ActionJobGates.gate(amount).release()
        try await settle(keeper)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("Cancelling the caller cancels its job, which ends with the cancellation")
    func callerCancellationCancelsJob() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        // A deadline far past the test's: only the forwarded cancellation can end the wait.
        let caller = Task {
            try await ResolverDeadline.$overrideForTesting.withValue(.seconds(120)) {
                try await keeper.handleActionEnvelope(gated(amount), playerID: p1, clientID: c1, sessionID: s1)
            }
        }
        await ActionJobGates.gate(amount).waitUntilEntered()
        caller.cancel()
        let result = try await withinDeadline("the cancelled caller") { await caller.result }
        expectCancellation(result)
        // The resolver group was abandoned at the cancellation; its task still holds the gate,
        // and the job keeps its place (its slot was read) until that task ends.
        #expect(await counts(keeper) == [1, 0])
        ActionJobGates.gate(amount).release()
        try await settle(keeper)
        #expect(await counts(keeper) == [0, 0])
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("A resolver-free action is handled through; a tickless land's action with resolvers is a job answered with the handler's response")
    func otherActionsCompleteInSubmit() async throws {
        let tick = await makeKeeper()
        try await tick.join(playerID: p1, clientID: c1, sessionID: s1)
        guard case .completed(let ack) = try await tick.submitAction(plain(5), playerID: p1, clientID: c1, sessionID: s1) else {
            Issue.record("Expected a resolver-free action to complete in submit")
            return
        }
        #expect(ack.base is Void)

        let tickless = await makeKeeper(tick: false)
        try await tickless.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        ActionJobGates.gate(amount).release()
        guard case .pending(let sequence) = try await tickless.submitAction(gated(amount), playerID: p1, clientID: c1, sessionID: s1) else {
            Issue.record("Expected a tickless land's action with resolvers to become a job")
            return
        }
        let response = try await tickless.awaitActionResult(sequence: sequence)
        let handlerAck = (response.base as? ActionJobAck) ?? ((response.base as? AnyCodable)?.base as? ActionJobAck)
        #expect(handlerAck?.ok == true, "unexpected response: \(response.base)")
        #expect(await counts(tickless) == [0, 0])
    }

    @Test("A caller cancelled before it submits starts no job, and its action isn't delivered")
    func preCancelledCallerStartsNoJob() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        // An instant resolver: a job, if started, would deliver before any later cancellation.
        ActionJobGates.gate(amount).release()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await keeper.handleActionEnvelope(gated(amount), playerID: p1, clientID: c1, sessionID: s1)
        }
        expectCancellation(try await withinDeadline("the pre-cancelled caller") { await caller.result })
        #expect(await keeper.actionJobCountsForTesting().started == 0)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("A caller cancelled after its resolvers finished, before the completion segment: not delivered")
    func callerCancelledBeforeCompletionSegment() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let hold = await holdCompletions(keeper)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        let caller = Task { try await keeper.awaitActionResult(sequence: sequence) }
        ActionJobGates.gate(amount).release()
        // The resolvers returned; the completion waits at its hold point.
        await hold.waitUntilEntered()
        caller.cancel()
        hold.release()
        expectCancellation(try await withinDeadline("the cancelled caller") { await caller.result })
        try await settle(keeper)
        #expect(await counts(keeper) == [0, 0])
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("A leave or the drain between the resolvers and the completion segment: rejected, the slot kept", arguments: [false, true])
    func rejectionBeforeCompletionSegment(drain: Bool) async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let hold = await holdCompletions(keeper)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        ActionJobGates.gate(amount).release()
        await hold.waitUntilEntered()

        var shutdown: Task<Void, Never>?
        if drain {
            shutdown = Task { await keeper.forceShutdown() }
        } else {
            try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        }
        let expected: LandInputRejection = drain ? .landClosed : .senderSuperseded
        try await expectRejection(expected) { try await keeper.awaitActionResult(sequence: sequence) }
        // The held completion then finds its job cancelled and leaves the outcome alone.
        hold.release()
        try await settle(keeper)
        await shutdown?.value
        #expect(await counts(keeper) == [0, 0])
        #expect(await keeper.currentState().total == 0)
    }

    @Test("A delivered job's action is bound to the tick current at its completion, not at its intake")
    func resolvedAtTickIsTheCompletionTick() async throws {
        let keeper = await makeKeeper(recording: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        let intakeTick = await keeper.debugLastCommittedTickId()
        let sequence = try await submitPending(keeper, amount)
        await ActionJobGates.gate(amount).waitUntilEntered()
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        let completionTick = await keeper.debugLastCommittedTickId()
        #expect(completionTick == intakeTick + 2)

        ActionJobGates.gate(amount).release()
        #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == amount)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let recorded = await recorder.getAllFrames().flatMap(\.actions).filter { $0.sequence == sequence }
        #expect(recorded.map(\.resolvedAtTick) == [completionTick])
    }

    @Test("A second read of a slot, or a read with no job, throws instead of answering")
    func missingOrSecondReadThrows() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = ActionJobGates.freshKey()
        let sequence = try await submitPending(keeper, amount)
        ActionJobGates.gate(amount).release()
        #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        await #expect(throws: ActionResultUnavailable(sequence: sequence)) {
            try await keeper.awaitActionResult(sequence: sequence)
        }
        await #expect(throws: ActionResultUnavailable(sequence: 9_999)) {
            try await keeper.awaitActionResult(sequence: 9_999)
        }
    }
}

/// Runs `body` with the given caps (0 removes one), resolver deadline and metrics, and, if
/// given, the hook an abandoned group's end awaits (`abandonedGroupEndedForTesting`).
private func withLimits<T: Sendable>(
    inFlight: Int,
    abandoned: Int,
    abandonedPerLand: Int = 0,
    deadline: Duration = .seconds(120),
    metrics: ResolverDeadlineMetrics,
    groupEnded: (@Sendable () async -> Void)? = nil,
    _ body: () async throws -> T
) async rethrows -> T {
    try await ActionJobLimits.$inFlightPerSessionOverrideForTesting.withValue(inFlight) {
        try await ActionJobLimits.$abandonedActionsOverrideForTesting.withValue(abandoned) {
            try await ActionJobLimits.$abandonedActionsPerLandOverrideForTesting.withValue(abandonedPerLand) {
                try await ResolverDeadline.$overrideForTesting.withValue(deadline) {
                    try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
                        try await ResolverDeadline.$abandonedGroupEndedForTesting.withValue(groupEnded) {
                            try await body()
                        }
                    }
                }
            }
        }
    }
}

private func expectLimit(
    _ expected: ActionLimitRejection,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> ActionSubmission
) async {
    do {
        let submission = try await body()
        Issue.record("Expected \(expected), got \(submission)", sourceLocation: sourceLocation)
    } catch {
        #expect(error as? ActionLimitRejection == expected, "got \(error)", sourceLocation: sourceLocation)
    }
}

/// Waits until a resolver timeout has abandoned the job at `sequence`: its caller gets the timeout.
private func expectTimedOut(_ keeper: LandKeeper<ActionJobTestState>, _ sequence: Int64) async throws {
    let result = try await withinDeadline("the deadline") { await outcome(of: { try await keeper.awaitActionResult(sequence: sequence) }) }
    guard case .failure(let error)? = result, case .timedOut? = error as? ResolverExecutionError else {
        Issue.record("Expected a resolver timeout, got \(String(describing: result))")
        return
    }
}

@Suite("Action jobs: the in-flight and abandoned caps", .timeLimit(.minutes(1)))
struct ActionJobLimitTests {
    @Test("The session's jobs past the cap are rejected; a resolver-free action and another session's job still pass")
    func perSessionCap() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let metrics = ResolverDeadlineMetrics()
        let a = ActionJobGates.freshKey(), b = ActionJobGates.freshKey(), c = ActionJobGates.freshKey(), other = ActionJobGates.freshKey()
        let pending: [Int64] = try await withLimits(inFlight: 2, abandoned: 0, metrics: metrics) {
            let first = try await submitPending(keeper, a)
            let second = try await submitPending(keeper, b)
            await expectLimit(.inFlightLimit(limit: 2)) {
                try await keeper.submitAction(gated(c), playerID: p1, clientID: c1, sessionID: s1)
            }
            guard case .completed = try await keeper.submitAction(plain(7), playerID: p1, clientID: c1, sessionID: s1) else {
                Issue.record("Expected the resolver-free action to complete")
                return [first, second]
            }
            let third = try await submitPending(keeper, other, player: p2, client: c2, session: s2)
            return [first, second, third]
        }
        #expect(metrics.snapshot.inFlightLimitRejections == 1)
        #expect(String(describing: ActionLimitRejection.inFlightLimit(limit: 2)).hasPrefix("action rejected: in-flight limit reached"))

        [a, b, other].forEach { ActionJobGates.gate($0).release() }
        for sequence in pending {
            #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        }
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == a + b + other + 7)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("A job abandoned at its deadline keeps its session's place until its resolvers end")
    func deadlineAbandonedJobKeepsItsPlace() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let stuck = ActionJobGates.freshKey(), next = ActionJobGates.freshKey()
        try await withLimits(inFlight: 1, abandoned: 0, deadline: .milliseconds(10), metrics: metrics) {
            let sequence = try await submitPending(keeper, stuck)
            try await expectTimedOut(keeper, sequence)
            #expect(metrics.snapshot.abandonedActions == 1)
            #expect(await counts(keeper) == [1, 0])
            await expectLimit(.inFlightLimit(limit: 1)) {
                try await keeper.submitAction(gated(next), playerID: p1, clientID: c1, sessionID: s1)
            }
        }
        ActionJobGates.gate(stuck).release()
        ActionJobGates.gate(next).release()
        try await settle(keeper)
        #expect(metrics.snapshot.abandonedActions == 0)
        #expect(await counts(keeper) == [0, 0])

        try await withLimits(inFlight: 1, abandoned: 0, metrics: metrics) {
            let sequence = try await submitPending(keeper, next)
            #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        }
    }

    @Test("A job abandoned by its caller's cancellation keeps its place, and the abandoned gauge comes down when it ends")
    func callerAbandonedJobKeepsItsPlace() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let stuck = ActionJobGates.freshKey(), next = ActionJobGates.freshKey()
        try await withLimits(inFlight: 1, abandoned: 0, metrics: metrics) {
            let sequence = try await submitPending(keeper, stuck)
            await ActionJobGates.gate(stuck).waitUntilEntered()
            let caller = Task { try await keeper.awaitActionResult(sequence: sequence) }
            caller.cancel()
            expectCancellation(try await withinDeadline("the cancelled caller") { await caller.result })
            #expect(metrics.snapshot.abandonedActions == 1)
            await expectLimit(.inFlightLimit(limit: 1)) {
                try await keeper.submitAction(gated(next), playerID: p1, clientID: c1, sessionID: s1)
            }
        }
        ActionJobGates.gate(stuck).release()
        ActionJobGates.gate(next).release()
        try await settle(keeper)
        #expect(metrics.snapshot.abandonedActions == 0)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("At the process-wide abandoned cap, actions with resolvers are rejected until one ends; others pass")
    func abandonedCap() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let metrics = ResolverDeadlineMetrics()
        let stuck = ActionJobGates.freshKey(), next = ActionJobGates.freshKey()
        try await withLimits(inFlight: 0, abandoned: 1, deadline: .milliseconds(10), metrics: metrics) {
            let sequence = try await submitPending(keeper, stuck)
            try await expectTimedOut(keeper, sequence)
            await expectLimit(.abandonedResolverLimit(limit: 1)) {
                try await keeper.submitAction(gated(next), playerID: p2, clientID: c2, sessionID: s2)
            }
            guard case .completed = try await keeper.submitAction(plain(3), playerID: p2, clientID: c2, sessionID: s2) else {
                Issue.record("Expected the resolver-free action to complete")
                return
            }
        }
        #expect(metrics.snapshot.abandonedLimitRejections == 1)
        #expect(String(describing: ActionLimitRejection.abandonedResolverLimit(limit: 1)).hasPrefix("action rejected: abandoned-resolver limit reached"))

        ActionJobGates.gate(stuck).release()
        ActionJobGates.gate(next).release()
        try await settle(keeper)
        #expect(metrics.snapshot.abandonedActions == 0)
        try await withLimits(inFlight: 0, abandoned: 1, metrics: metrics) {
            let sequence = try await submitPending(keeper, next, player: p2, client: c2, session: s2)
            #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        }
    }

    @Test("An awaiting caller (handleActionEnvelope) isn't capped: direct callers may send concurrently, as before")
    func awaitingCallerIsNotCapped() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let amounts = (0..<3).map { _ in ActionJobGates.freshKey() }
        defer { amounts.forEach { ActionJobGates.gate($0).release() } }
        let callers = try await withLimits(inFlight: 1, abandoned: 0, metrics: metrics) {
            var callers: [Task<AnyCodable, any Error>] = []
            for amount in amounts {
                let caller = Task {
                    try await keeper.handleActionEnvelope(gated(amount), playerID: p1, clientID: c1, sessionID: s1)
                }
                callers.append(caller)
                // A capped caller is rejected and never enters its resolver.
                _ = try await withinDeadline("the resolver of \(amount) is entered") {
                    await ActionJobGates.gate(amount).waitUntilEntered()
                }
            }
            return callers
        }
        #expect(await counts(keeper) == [3, 3])
        amounts.forEach { ActionJobGates.gate($0).release() }
        for caller in callers {
            #expect(try await caller.value.base is Void)
        }
        #expect(metrics.snapshot.inFlightLimitRejections == 0)
    }

    @Test("Abandoned jobs give their places back when their resolvers end: after 8, the session is not locked out")
    func abandonedPlacesComeBack() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let stuck = (0..<8).map { _ in ActionJobGates.freshKey() }, next = ActionJobGates.freshKey()
        defer { (stuck + [next]).forEach { ActionJobGates.gate($0).release() } }
        try await withLimits(inFlight: 8, abandoned: 0, deadline: .milliseconds(10), metrics: metrics) {
            for amount in stuck {
                try await expectTimedOut(keeper, try await submitPending(keeper, amount))
            }
            await expectLimit(.inFlightLimit(limit: 8)) {
                try await keeper.submitAction(gated(next), playerID: p1, clientID: c1, sessionID: s1)
            }
        }
        stuck.forEach { ActionJobGates.gate($0).release() }
        // Observation only: the places come back through the release each `onEnded` schedules.
        try await settle(keeper)
        #expect(await counts(keeper) == [0, 0])
        ActionJobGates.gate(next).release()
        try await withLimits(inFlight: 8, abandoned: 0, metrics: metrics) {
            let sequence = try await submitPending(keeper, next)
            #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        }
    }

    @Test("A caller cancelled from another thread just before the job waits on its race: the job keeps its place, the abandonment is counted")
    func callerCancelBeforeTheRaceWait() async throws {
        let keeper = await makeKeeper()
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let amount = ActionJobGates.freshKey(), rejected = ActionJobGates.freshKey()
        defer { ActionJobGates.gate(amount).release() }
        let atWait = SyncSignal(), settled = SyncSignal(), proceed = SyncSignal()
        defer { proceed.signal() }
        try await withLimits(inFlight: 1, abandoned: 0, metrics: metrics) {
            // The job's task inherits the hook: it stops just before it waits on the race,
            // until the cancellation below has settled it.
            let sequence = try await ResolverDeadline.$beforeRaceWaitForTesting.withValue({
                atWait.signal()
                settled.wait()
            }) {
                try await submitPending(keeper, amount)
            }
            _ = try await withinDeadline("the job reaches its race") { await atWait.waitAsync() }
            let caller = Task { try await keeper.awaitActionResult(sequence: sequence) }
            _ = try await withinDeadline("the caller waits") { () async -> Void in
                while !(await keeper.actionResultHasWaiterForTesting(sequence)) { await Task.yield() }
            }
            // The canceller settles the race on its own thread and stops there, before its
            // handler returns. The job sees the outcome; the runtime lets it leave its
            // cancellation handler only once the canceller's handler returned.
            let canceller = Task.detached {
                ResolverDeadline.$afterRaceSettledForTesting.withValue({
                    settled.signal()
                    proceed.wait()
                }) {
                    caller.cancel()
                }
            }
            _ = try await withinDeadline("the race is settled") { await settled.waitAsync() }
            proceed.signal()
            await canceller.value
            expectCancellation(try await withinDeadline("the cancelled caller") { await caller.result })
            #expect(metrics.snapshot.abandonedActions == 1, "counted when the race was settled")
            #expect(await counts(keeper) == [1, 0], "the job keeps its place while its resolver runs")
            await expectLimit(.inFlightLimit(limit: 1)) {
                try await keeper.submitAction(gated(rejected), playerID: p1, clientID: c1, sessionID: s1)
            }
        }
        ActionJobGates.gate(amount).release()
        try await settle(keeper)
        #expect(metrics.snapshot.abandonedActions == 0)
        #expect(await counts(keeper) == [0, 0])
    }

    @Test("The caps parse like the resolver deadline: 0 removes a cap, a negative value gives the default")
    func capsParse() {
        let key = EnvKeys.Runtime.actionInFlightMaxPerSession
        #expect(ActionJobLimits.parse(key, default: 8, environment: [:]) == 8)
        #expect(ActionJobLimits.parse(key, default: 8, environment: [key: "3"]) == 3)
        #expect(ActionJobLimits.parse(key, default: 8, environment: [key: "0"]) == nil)
        #expect(ActionJobLimits.parse(key, default: 8, environment: [key: "-1"]) == 8)
    }
}

/// A one-shot signal that a synchronous hook can wait on (bounded, 10 s) and a test can await.
private final class SyncSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let toResume: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            defer { waiters = [] }
            return waiters
        }
        guard let toResume else { return }
        semaphore.signal()
        toResume.forEach { $0.resume() }
    }

    /// Blocks the calling thread until `signal()`, at most 10 s.
    func wait() {
        _ = semaphore.wait(timeout: .now() + .seconds(10))
        semaphore.signal()
    }

    func waitAsync() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard !fired else { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}

// MARK: - Per-land and per-kind abandonment (#364)

/// One gate per key for the lifecycle resolvers below; a resolver waits on its gate when its
/// session's ID is `<kind>-<key>`, and returns at once otherwise.
private enum KindGates {
    private static let keys = KeyedGates(firstKey: 50_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> WatermarkGate { keys.gate(key, sourceLocation: sourceLocation) }
}

/// Ignores cancellation, like `ActionJobGatedResolver`.
private func waitOnKindGate(_ ctx: ResolverContext, _ kind: ResolverAbandonment.Kind) async {
    let id = ctx.sessionID.rawValue
    let prefix = "\(kind.rawValue)-"
    guard id.hasPrefix(prefix), let key = Int(id.dropFirst(prefix.count)) else { return }
    await KindGates.gate(key).enterAndWait()
}

struct KindCanJoinResolver: ContextResolver {
    typealias Output = ActionJobResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> ActionJobResolverOutput {
        await waitOnKindGate(ctx, .canJoin)
        return ActionJobResolverOutput(value: 0)
    }
}

struct KindOnJoinResolver: ContextResolver {
    typealias Output = ActionJobResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> ActionJobResolverOutput {
        await waitOnKindGate(ctx, .onJoin)
        return ActionJobResolverOutput(value: 0)
    }
}

struct KindOnLeaveResolver: ContextResolver {
    typealias Output = ActionJobResolverOutput
    static func resolve(ctx: ResolverContext) async throws -> ActionJobResolverOutput {
        await waitOnKindGate(ctx, .onLeave)
        return ActionJobResolverOutput(value: 0)
    }
}

/// A tick land with the gated action and gated CanJoin, OnJoin and OnLeave resolvers.
private func makeKindKeeper(_ name: String) async -> LandKeeper<ActionJobTestState> {
    let definition = Land("action-job-kinds", using: ActionJobTestState.self) {
        Rules {
            HandleAction(ActionJobGatedAction.self, resolvers: ActionJobGatedResolver.self) {
                (state: inout ActionJobTestState, action: ActionJobGatedAction, _: LandContext) in
                state.total += action.amount
                return ActionJobAck(ok: true)
            }
            CanJoin(resolvers: KindCanJoinResolver.self) { (_: ActionJobTestState, session: PlayerSession, _: LandContext) in
                .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin(resolvers: KindOnJoinResolver.self) { (_: inout ActionJobTestState, _: LandContext) in }
            OnLeave(resolvers: KindOnLeaveResolver.self) { (_: inout ActionJobTestState, _: LandContext) in }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout ActionJobTestState, _: LandContext) in }
        }
    }
    let keeper = LandKeeper<ActionJobTestState>(
        definition: definition,
        initialState: ActionJobTestState(),
        autoStartLoops: false
    )
    await keeper.setLandID("action-job-kinds:\(name)")
    return keeper
}

/// Joins through CanJoin and OnJoin, as a router join does.
private func joinThroughCanJoin(_ keeper: LandKeeper<ActionJobTestState>, player: String, session: String) async throws {
    _ = try await keeper.join(
        session: PlayerSession(playerID: player, deviceID: "dev", metadata: [:]),
        clientID: ClientID("c-\(player)"),
        sessionID: SessionID(session),
        services: LandServices()
    )
}

/// Waits until `keeper`'s count of `kind` is `count`, resumed by the transition, within a
/// deadline: a missing end fails the test instead of hanging it.
private func expectAbandoned(
    _ keeper: LandKeeper<ActionJobTestState>,
    _ kind: ResolverAbandonment.Kind,
    _ count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    _ = try await withinDeadline("\(kind) abandoned count \(count)", sourceLocation: sourceLocation) {
        await keeper.abandonmentCounter.waitForCount(kind, count)
    }
    #expect(keeper.abandonmentCounter.count(kind) == count, sourceLocation: sourceLocation)
}

/// Abandons one group of `kind` on `keeper` at its deadline; returns the gate holding it.
private func abandonOne(_ keeper: LandKeeper<ActionJobTestState>, _ kind: ResolverAbandonment.Kind) async throws -> WatermarkGate {
    let key = KindGates.freshKey()
    let session = "\(kind.rawValue)-\(key)"
    switch kind {
    case .canJoin, .onJoin:
        // The join times out in its resolvers: it throws, and the group is abandoned.
        await #expect(throws: (any Error).self) { try await joinThroughCanJoin(keeper, player: "k\(key)", session: session) }
    case .onLeave:
        try await joinThroughCanJoin(keeper, player: "k\(key)", session: session)
        // The leave's OnLeave resolvers time out: it throws, and its OnLeave is dropped.
        await #expect(throws: (any Error).self) {
            try await keeper.leave(playerID: PlayerID("k\(key)"), clientID: ClientID("c-k\(key)"), sessionID: SessionID(session))
        }
    case .action, .onInitialize:
        Issue.record("abandonOne covers the join and leave kinds")
    }
    return KindGates.gate(key)
}

@Suite("Resolver abandonment: per land and per kind (#364)", .timeLimit(.minutes(1)))
struct ResolverAbandonmentTests {
    @Test("At the per-land cap, a land's next resolver action is refused; another land's runs; the land's own runs again once its groups end")
    func perLandActionCap() async throws {
        let a = await makeKindKeeper("a"), b = await makeKindKeeper("b")
        try await a.join(playerID: p1, clientID: c1, sessionID: s1)
        try await b.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let stuck1 = ActionJobGates.freshKey(), stuck2 = ActionJobGates.freshKey()
        let refused = ActionJobGates.freshKey(), onB = ActionJobGates.freshKey(), after = ActionJobGates.freshKey()
        try await withLimits(inFlight: 0, abandoned: 0, abandonedPerLand: 2, deadline: .milliseconds(10), metrics: metrics) {
            for key in [stuck1, stuck2] {
                let sequence = try await submitPending(a, key)
                try await expectTimedOut(a, sequence)
            }
            #expect(a.abandonmentCounter.count(.action) == 2)
            await expectLimit(.landAbandonedResolverLimit(limit: 2)) {
                try await a.submitAction(gated(refused), playerID: p1, clientID: c1, sessionID: s1)
            }
            #expect(metrics.snapshot.landAbandonedLimitRejections == 1)
        }
        try await withLimits(inFlight: 0, abandoned: 0, abandonedPerLand: 2, metrics: metrics) {
            // The other land's count is its own.
            let sequence = try await submitPending(b, onB)
            ActionJobGates.gate(onB).release()
            #expect(try await b.awaitActionResult(sequence: sequence).base is Void)

            ActionJobGates.gate(stuck1).release()
            ActionJobGates.gate(stuck2).release()
            try await expectAbandoned(a, .action, 0)
            let next = try await submitPending(a, after)
            ActionJobGates.gate(after).release()
            #expect(try await a.awaitActionResult(sequence: next).base is Void)
        }
        ActionJobGates.gate(refused).release()
        #expect(String(describing: ActionLimitRejection.landAbandonedResolverLimit(limit: 2)).hasPrefix("action rejected: abandoned-resolver limit reached"))
    }

    @Test("Kinds are counted apart: an abandoned join or leave group doesn't count toward the action cap", arguments: [ResolverAbandonment.Kind.canJoin, .onJoin, .onLeave])
    func kindsAreSeparate(kind: ResolverAbandonment.Kind) async throws {
        let keeper = await makeKindKeeper("kinds-\(kind.rawValue)")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let action = ActionJobGates.freshKey()
        let gate = try await withLimits(inFlight: 0, abandoned: 0, abandonedPerLand: 1, deadline: .milliseconds(10), metrics: metrics) {
            try await abandonOne(keeper, kind)
        }
        #expect(keeper.abandonmentCounter.count(kind) == 1)
        #expect(keeper.abandonmentCounter.count(.action) == 0)
        try await withLimits(inFlight: 0, abandoned: 0, abandonedPerLand: 1, metrics: metrics) {
            // The cap is 1 and a group of another kind is abandoned: actions still run.
            let sequence = try await submitPending(keeper, action)
            ActionJobGates.gate(action).release()
            #expect(try await keeper.awaitActionResult(sequence: sequence).base is Void)
        }
        gate.release()
        try await expectAbandoned(keeper, kind, 0)
    }

    @Test("Every abandoned gauge moves exactly once each way: back to 0 after an action and a join end, not below")
    func gaugesMoveOnce() async throws {
        let keeper = await makeKindKeeper("gauges")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let stuck = ActionJobGates.freshKey()
        let joinGate = try await withLimits(inFlight: 0, abandoned: 0, deadline: .milliseconds(10), metrics: metrics) {
            let sequence = try await submitPending(keeper, stuck)
            try await expectTimedOut(keeper, sequence)
            return try await abandonOne(keeper, .canJoin)
        }
        let during = metrics.snapshot
        #expect(during.abandoned == 2)
        #expect(during.abandonedActions == 1)
        #expect(during.abandonedCanJoin == 1)

        ActionJobGates.gate(stuck).release()
        joinGate.release()
        try await expectAbandoned(keeper, .action, 0)
        try await expectAbandoned(keeper, .canJoin, 0)
        try await settle(keeper)
        let after = metrics.snapshot
        #expect(after.abandoned == 0)
        #expect(after.abandonedActions == 0)
        #expect(after.abandonedCanJoin == 0)
        #expect(after.timeouts == 2)
    }

    @Test("On the cancel path the end is counted after the begin: 1 while the end is held, 0 after, never below")
    func cancelPathBeginBeforeEnd() async throws {
        let keeper = await makeKindKeeper("cancel")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let metrics = ResolverDeadlineMetrics()
        let endGate = WatermarkGate()
        let stuck = ActionJobGates.freshKey()
        try await withLimits(inFlight: 0, abandoned: 0, metrics: metrics, groupEnded: { await endGate.enterAndWait() }) {
            let sequence = try await submitPending(keeper, stuck)
            await ActionJobGates.gate(stuck).waitUntilEntered()
            let caller = Task { try await keeper.awaitActionResult(sequence: sequence) }
            caller.cancel()
            expectCancellation(try await withinDeadline("the cancelled caller") { await caller.result })
        }
        #expect(keeper.abandonmentCounter.count(.action) == 1)
        #expect(metrics.snapshot.abandoned == 1)
        #expect(metrics.snapshot.timeouts == 0, "a cancellation isn't a timeout")

        // The group ends; its end transition is held.
        ActionJobGates.gate(stuck).release()
        await endGate.waitUntilEntered()
        #expect(keeper.abandonmentCounter.count(.action) == 1)
        #expect(metrics.snapshot.abandonedActions == 1)
        endGate.release()
        try await expectAbandoned(keeper, .action, 0)
        try await settle(keeper)
        #expect(metrics.snapshot.abandoned == 0)
        #expect(metrics.snapshot.abandonedActions == 0)
    }
}
