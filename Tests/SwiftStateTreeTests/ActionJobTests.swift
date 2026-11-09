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
enum ActionJobGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [Int: WatermarkGate] = [:]

    static func gate(_ key: Int) -> WatermarkGate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            let gate = WatermarkGate()
            gates[key] = gate
            return gate
        }
    }
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
        let amount = 1_001
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
        let amount = 1_002
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
        let amount = 1_003
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
        let old = 1_011, other = 1_012, newer = 1_013
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
        let amount = 1_021
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
        let amount = 1_031
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
        let amount = 1_041
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
        let amount = 1_051
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
        let amount = 1_061
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
        let amount = drain ? 1_072 : 1_071
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
        let amount = 1_081
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
        let amount = 1_091
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

/// Runs `body` with the given caps (0 removes one), resolver deadline and metrics.
private func withLimits<T: Sendable>(
    inFlight: Int,
    abandoned: Int,
    deadline: Duration = .seconds(120),
    metrics: ResolverDeadlineMetrics,
    _ body: () async throws -> T
) async rethrows -> T {
    try await ActionJobLimits.$inFlightPerSessionOverrideForTesting.withValue(inFlight) {
        try await ActionJobLimits.$abandonedActionsOverrideForTesting.withValue(abandoned) {
            try await ResolverDeadline.$overrideForTesting.withValue(deadline) {
                try await ResolverDeadline.$metricsForTesting.withValue(metrics) {
                    try await body()
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
        let a = 2_001, b = 2_002, c = 2_003, other = 2_004
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
        let stuck = 2_011, next = 2_012
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
        let stuck = 2_021, next = 2_022
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
        let stuck = 2_031, next = 2_032
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
        let amounts = [2_041, 2_042, 2_043]
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
        let stuck = Array(2_051...2_058), next = 2_059
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
        let amount = 2_071
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
                try await keeper.submitAction(gated(amount + 1), playerID: p1, clientID: c1, sessionID: s1)
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
