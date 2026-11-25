// Tests/SwiftStateTreeTests/HeldFailureTests.swift
//
// An error the keeper holds for a caller (an action job's slot, an input turn's outcome, the
// initialization's failure) reaches that caller as the same value (#700 K1b-2). Commit 1: green
// on K1b-1's base, before the failure table exists. The tests that read the table's hooks are in
// HeldFailureTableTests, which lands with the change.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct HeldFailureState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

/// An error with an identity: a test compares the value its caller gets, not only its type.
struct HeldFailureError: Error, Equatable {
    let token: Int
}

@Payload
struct HeldFailureAck: ResponsePayload {
    let ok: Bool
}

/// Its resolver waits at its gate, then throws `HeldFailureError(token: key)`.
@Payload
struct HeldFailureResolverAction: ActionPayload {
    typealias Response = HeldFailureAck
    let key: Int
}

/// No resolver; `validate` throws `HeldFailureError(token: token)`.
@Payload
struct HeldFailureValidateAction: ActionPayload {
    typealias Response = HeldFailureAck
    let token: Int
}

/// A resolver that succeeds after its gate; `validate` then throws `HeldFailureError(token: key)`.
@Payload
struct HeldFailureResolvedValidateAction: ActionPayload {
    typealias Response = HeldFailureAck
    let key: Int
}

@Payload
struct HeldFailureServerInput: ServerInputPayload {
    let n: Int
}

/// `validate` throws `HeldFailureError(token: token)`.
@Payload
struct HeldFailureEvent: ClientEventPayload {
    let token: Int
}

@PlainData
struct HeldFailureOutput: ResolverOutput {
    let key: Int
}

/// One gate per key; keys only from `freshKey()`.
enum HeldFailureGates {
    private static let keys = KeyedGates(firstKey: 9_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> WatermarkGate { keys.gate(key, sourceLocation: sourceLocation) }
}

@PlainData
struct HeldFailureThrowingResolver: Resolver {
    typealias Dependencies = NoServices
    let key: Int
    typealias Output = HeldFailureOutput

    func resolve(_ deps: NoServices) async throws -> HeldFailureOutput {
        let key = key
        await HeldFailureGates.gate(key).enterAndWait()
        throw HeldFailureError(token: key)
    }
}

@PlainData
struct HeldFailureGatedResolver: Resolver {
    typealias Dependencies = NoServices
    let key: Int
    typealias Output = HeldFailureOutput

    func resolve(_ deps: NoServices) async throws -> HeldFailureOutput {
        let key = key
        await HeldFailureGates.gate(key).enterAndWait()
        return HeldFailureOutput(key: key)
    }
}

func heldFailureDefinitionForTables(tick: Bool) -> LandDefinition<HeldFailureState> { makeDefinition(tick: tick) }

private func makeDefinition(tick: Bool) -> LandDefinition<HeldFailureState> {
    Land("held-failure", using: HeldFailureState.self) {
        ClientEvents { Register(HeldFailureEvent.self) }
        Rules {
            HandleAction(HeldFailureResolverAction.self, resolvers: { _, action, _ in HeldFailureThrowingResolver(key: action.key) }) {
                _, _, _, _ in HeldFailureAck(ok: true)
            }
            HandleAction(HeldFailureValidateAction.self, validate: { _, action, _ in
                throw HeldFailureError(token: action.token)
            }, apply: { _, _, _, _ in HeldFailureAck(ok: true) })
            HandleAction(HeldFailureResolvedValidateAction.self, resolvers: { _, action, _ in HeldFailureGatedResolver(key: action.key) }, validate: {
                _, action, _, _ in
                throw HeldFailureError(token: action.key)
            }, apply: { _, _, _, _, _ in HeldFailureAck(ok: true) })
            HandleEvent(HeldFailureEvent.self, validate: { _, event, _ in
                throw HeldFailureError(token: event.token)
            }, apply: { state, _, _ in state.total += 1 })
        }
        if tick {
            Lifetime { Tick(every: .seconds(3600)) { _, _ in } }
        }
    }
}

/// OnInitialize's validate throws `HeldFailureError(token: initToken)`.
private let initToken = 5_150

private func makeFailingInitDefinition() -> LandDefinition<HeldFailureState> {
    Land("held-failure-init", using: HeldFailureState.self) {
        ClientEvents { Register(HeldFailureEvent.self) }
        Rules {
            HandleAction(HeldFailureValidateAction.self, validate: { _, action, _ in
                throw HeldFailureError(token: action.token)
            }, apply: { _, _, _, _ in HeldFailureAck(ok: true) })
            HandleEvent(HeldFailureEvent.self, validate: { _, event, _ in
                throw HeldFailureError(token: event.token)
            }, apply: { state, _, _ in state.total += 1 })
        }
        Lifetime {
            OnInitialize(validate: { _, _ in throw HeldFailureError(token: initToken) }, apply: { _, _ in })
        }
    }
}

private func makeKeeper(tick: Bool) -> LandKeeper<HeldFailureState> {
    LandKeeper<HeldFailureState>(
        definition: makeDefinition(tick: tick),
        initialState: HeldFailureState(),
        autoStartLoops: false,
        landID: "held-failure:local"
    )
}

private func envelope(_ payload: some ActionPayload) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: type(of: payload)), payload: AnyCodable(payload))
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// A resolver's error as the job's caller gets it: wrapped with the resolver's name.
private func resolverError(_ error: (any Error)?) -> HeldFailureError? {
    guard case .resolverFailed(_, let underlying)? = error as? ResolverExecutionError else { return nil }
    return underlying as? HeldFailureError
}

/// The error the body throws, or an issue if it returned.
private func thrown(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> (any Error)? {
    do {
        try await body()
        Issue.record("Expected an error", sourceLocation: sourceLocation)
        return nil
    } catch {
        return error
    }
}

/// Submits `action`, expects a pending job, and returns its sequence.
private func submitPending(_ keeper: LandKeeper<HeldFailureState>, _ action: some ActionPayload, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int64 {
    let submission = try await keeper.submitAction(envelope(action), playerID: p1, clientID: c1, sessionID: s1)
    guard case .pending(let sequence) = submission else {
        Issue.record("Expected a pending job, got \(submission)", sourceLocation: sourceLocation)
        return -1
    }
    return sequence
}

@Suite("Held failures reach their callers as the same value", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct HeldFailureTests {
    @Test("A resolver's error reaches the job's caller as the same value, read waiting or late", arguments: [true, false])
    func failedActionResultReachesItsCallerAsTheSameValue(tick: Bool) async throws {
        let keeper = makeKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        // Waiting: the caller reads before the resolver ends.
        let waitingKey = HeldFailureGates.freshKey()
        let waitingSequence = try await submitPending(keeper, HeldFailureResolverAction(key: waitingKey))
        let waiting = Task { await thrown { _ = try await keeper.awaitActionResult(sequence: waitingSequence) } }
        #expect(try await withinDeadline("the caller waits") { await keeper.waitUntilActionResultHasWaiterForTesting(waitingSequence) } == true, "the caller waits")
        HeldFailureGates.gate(waitingKey).release()
        #expect(resolverError(await waiting.value) == HeldFailureError(token: waitingKey))

        // Late: the resolver ended and the slot was filled before the read.
        let lateKey = HeldFailureGates.freshKey()
        let lateSequence = try await submitPending(keeper, HeldFailureResolverAction(key: lateKey))
        HeldFailureGates.gate(lateKey).release()
        #expect(try await withinDeadline("the slot is filled") { await keeper.waitUntilActionSlotFilledForTesting(lateSequence) } == true, "the slot is filled")
        let late = await thrown { _ = try await keeper.awaitActionResult(sequence: lateSequence) }
        #expect(resolverError(late) == HeldFailureError(token: lateKey))
    }

    @Test("On a tickless land, a handler's validate error reaches the caller as the same value")
    func failedValidateReachesItsCaller() async throws {
        let keeper = makeKeeper(tick: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let error = await thrown {
            _ = try await keeper.handleActionEnvelope(envelope(HeldFailureValidateAction(token: 41)), playerID: p1, clientID: c1, sessionID: s1)
        }
        #expect(error as? HeldFailureError == HeldFailureError(token: 41))
    }

    @Test("On a tickless land, a resolver action whose validate throws: the job's slot gets the same value, waiting or late")
    func resolvedValidateErrorReachesTheSlot() async throws {
        let keeper = makeKeeper(tick: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        // Late only: the turn answers through `inputTurnResults`, then the resume fills the slot
        // with nobody waiting (the path that stores a failure under the slot).
        let key = HeldFailureGates.freshKey()
        let sequence = try await submitPending(keeper, HeldFailureResolvedValidateAction(key: key))
        HeldFailureGates.gate(key).release()
        #expect(try await withinDeadline("the slot is filled") { await keeper.waitUntilActionSlotFilledForTesting(sequence) } == true, "the slot is filled")
        let error = await thrown { _ = try await keeper.awaitActionResult(sequence: sequence) }
        #expect(error as? HeldFailureError == HeldFailureError(token: key))
    }

    @Test("An action over the session's job cap is refused by submit: no sequence, no slot")
    func actionLimitRejectionIsAnIntakeRefusal() async throws {
        try await ActionJobLimits.$inFlightPerSessionOverrideForTesting.withValue(1) {
            let keeper = makeKeeper(tick: true)
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
            let held = HeldFailureGates.freshKey()
            _ = try await submitPending(keeper, HeldFailureResolverAction(key: held))
            let before = await keeper.actionJobCountsForTesting()
            let error = await thrown {
                _ = try await keeper.submitAction(envelope(HeldFailureResolverAction(key: HeldFailureGates.freshKey())), playerID: p1, clientID: c1, sessionID: s1)
            }
            #expect(error is ActionLimitRejection, "got \(String(describing: error))")
            let after = await keeper.actionJobCountsForTesting()
            #expect(after.jobs == before.jobs && after.slots == before.slots && after.started == before.started)
            HeldFailureGates.gate(held).release()
        }
    }

    @Test("On a tickless land, a client event whose validate throws: the caller gets the same value after the record")
    func failedInputTurnOutcomeReachesItsCaller() async throws {
        let keeper = makeKeeper(tick: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let error = await thrown {
            try await keeper.handleClientEvent(AnyClientEvent(HeldFailureEvent(token: 77)), playerID: p1, clientID: c1, sessionID: s1)
        }
        #expect(error as? HeldFailureError == HeldFailureError(token: 77))
    }

    @Test("A failed slot left unread through the drain is read once, with the exact rejection")
    func aFailedSlotIsReadThroughTeardown() async throws {
        let keeper = makeKeeper(tick: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let key = HeldFailureGates.freshKey()
        let sequence = try await submitPending(keeper, HeldFailureResolverAction(key: key))
        guard await HeldFailureGates.gate(key).waitUntilEntered() else { return }
        await keeper.forceShutdown()
        HeldFailureGates.gate(key).release()
        let first = await thrown { _ = try await keeper.awaitActionResult(sequence: sequence) }
        #expect(first as? LandInputRejection == .landClosed, "got \(String(describing: first))")
        let second = await thrown { _ = try await keeper.awaitActionResult(sequence: sequence) }
        #expect(second is ActionResultUnavailable, "got \(String(describing: second))")
    }
    @Test("The initialization's failure reaches every later caller as the same value; a join maps it, a server input is refused")
    func initializationFailureReachesEachCallerAsTheSameValue() async throws {
        let keeper = LandKeeper<HeldFailureState>(
            definition: makeFailingInitDefinition(),
            initialState: HeldFailureState(),
            autoStartLoops: false,
            landID: "held-failure-init:local"
        )
        // Two successive external calls of each kind; the init's eager task read first.
        for _ in 0..<2 {
            let action = await thrown {
                _ = try await keeper.handleActionEnvelope(envelope(HeldFailureValidateAction(token: 1)), playerID: p1, clientID: c1, sessionID: s1)
            }
            #expect((action as? LandInitializationError)?.underlying as? HeldFailureError == HeldFailureError(token: initToken), "action: \(String(describing: action))")
            let event = await thrown {
                try await keeper.handleClientEvent(AnyClientEvent(HeldFailureEvent(token: 2)), playerID: p1, clientID: c1, sessionID: s1)
            }
            #expect((event as? LandInitializationError)?.underlying as? HeldFailureError == HeldFailureError(token: initToken), "event: \(String(describing: event))")
            let leave = await thrown { try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1) }
            #expect((leave as? LandInitializationError)?.underlying as? HeldFailureError == HeldFailureError(token: initToken), "leave: \(String(describing: leave))")
        }
        let join = await thrown { try await keeper.join(playerID: p1, clientID: c1, sessionID: s1) }
        if case .landShuttingDown? = join as? JoinError {} else { Issue.record("join: \(String(describing: join))") }
        #expect(await keeper.submitServerInput(HeldFailureServerInput(n: 1)) == .refused(.draining))
    }
}
