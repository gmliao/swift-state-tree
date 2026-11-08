// Tests/SwiftStateTreeTests/ActionJobTests.swift
//
// On a tick land, an action with resolvers is a job: `submitAction` registers it and returns
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
        await keeper.waitForActionJobsForTesting()
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
        await keeper.waitForActionJobsForTesting()
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
        await keeper.waitForActionJobsForTesting()
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
        await keeper.waitForActionJobsForTesting()
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
        // The resolver group was abandoned at the cancellation; its task still holds the gate.
        await keeper.waitForActionJobsForTesting()
        #expect(await counts(keeper) == [0, 0])
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
        ActionJobGates.gate(amount).release()
    }

    @Test("A resolver-free action and a tickless land's action are handled through, as before")
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
        guard case .completed(let response) = try await tickless.submitAction(gated(amount), playerID: p1, clientID: c1, sessionID: s1) else {
            Issue.record("Expected a tickless land's action to complete in submit")
            return
        }
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
        await keeper.waitForActionJobsForTesting()
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
        await keeper.waitForActionJobsForTesting()
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
