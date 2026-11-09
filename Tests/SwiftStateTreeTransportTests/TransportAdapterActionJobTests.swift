// Tests/SwiftStateTreeTransportTests/TransportAdapterActionJobTests.swift
//
// On a tick land, the adapter submits an action on the session's inbound chain and answers an
// action with resolvers from a tracked task, so the chain moves on while the resolvers run.
// Responses come in completion order, each under its own requestID. A disconnect drops the
// session's pending responses: nothing is sent to it, no task stays tracked, and the keeper's
// slots are read. Every answer (a pending one, an ACK, an error) is checked against the
// connection's ticket, so a reconnect that reuses the SessionID gets none of the old ones.
// Interleavings are forced with gates and hold points; waits are on continuations, bounded.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct AdapterJobTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0
}

@Payload
struct AdapterJobAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct AdapterJobHeldAction: ActionPayload {
    typealias Response = AdapterJobAck
    /// Also the key of the resolver's gate (`AdapterJobGates`).
    let key: Int
}

@Payload
struct AdapterJobPlainAction: ActionPayload {
    typealias Response = AdapterJobAck
    let amount: Int
}

/// Not registered with the land: its intake throws `actionNotRegistered`.
@Payload
struct AdapterJobUnregisteredAction: ActionPayload {
    typealias Response = AdapterJobAck
    let amount: Int
}

struct AdapterJobOutput: ResolverOutput {}

/// A gate that code under test arrives at and waits on until it's opened; the test awaits the
/// arrival on a continuation, not a poll.
private final class HeldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            arrived = true
            defer { arrivalWaiters = [] }
            return arrivalWaiters
        }
        toResume.forEach { $0.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard !isOpen else { return true }
                openWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func waitUntilArrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard !arrived else { return true }
                arrivalWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { openWaiters = [] }
            return openWaiters
        }
        toResume.forEach { $0.resume() }
    }
}

/// One gate per action key: resolvers are static, and parallel tests must not share a gate.
/// Keys come only from `freshKey()`, never a literal.
private enum AdapterJobGates {
    private static let keys = KeyedGates(firstKey: 3_000) { HeldGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> HeldGate { keys.gate(key, sourceLocation: sourceLocation) }
}

struct AdapterJobHeldResolver: ContextResolver {
    typealias Output = AdapterJobOutput

    static func resolve(ctx: ResolverContext) async throws -> AdapterJobOutput {
        let key = (ctx.actionPayload as? AdapterJobHeldAction)?.key ?? -1
        await AdapterJobGates.gate(key).arrive()
        return AdapterJobOutput()
    }
}

/// Records frames in send order.
private actor AdapterJobTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append((message, target)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// The requestIDs `sessionID` got an answer for, in order: "<id>" for an action response,
    /// "error:<id>" for an error.
    func answers(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .session(let s) = frame.target, s == sessionID,
                  let message = try? JSONDecoder().decode(TransportMessage.self, from: frame.data) else { return nil }
            switch message.payload {
            case .actionResponse(let payload):
                return payload.requestID
            case .error(let payload):
                return "error:\(payload.details?["requestID"]?.base as? String ?? "?")"
            default:
                return nil
            }
        }
    }
}

private struct Fixture {
    let keeper: LandKeeper<AdapterJobTestState>
    let adapter: TransportAdapter<AdapterJobTestState>
    let transport: AdapterJobTransport

    func join(_ session: SessionID, _ client: ClientID, as player: String) async throws {
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: player, deviceID: "dev", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil
        )
        let joined = try #require(result)
        await adapter.syncStateForNewPlayer(playerID: joined.playerID, sessionID: session)
    }

    func send(_ requestID: String, _ action: some ActionPayload, from session: SessionID) async throws {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action))
        let message = TransportMessage.action(requestID: requestID, action: envelope)
        await adapter.onMessage(try JSONEncoder().encode(message), from: session)
    }

    func answers(for session: SessionID) async -> [String] {
        _ = await adapter.waitForOutboundDrain()
        return await transport.answers(for: session)
    }
}

private func makeFixture() async -> Fixture {
    let definition = Land("adapter-job", using: AdapterJobTestState.self) {
        Rules {
            HandleAction(AdapterJobHeldAction.self, resolvers: AdapterJobHeldResolver.self) {
                (_: inout AdapterJobTestState, _: AdapterJobHeldAction, _: LandContext) in
                AdapterJobAck(ok: true)
            }
            HandleAction(AdapterJobPlainAction.self) {
                (state: inout AdapterJobTestState, action: AdapterJobPlainAction, _: LandContext) in
                state.total += action.amount
                return AdapterJobAck(ok: true)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout AdapterJobTestState, _: LandContext) in }
        }
    }
    let transport = AdapterJobTransport()
    let keeper = LandKeeper(definition: definition, initialState: AdapterJobTestState(), autoStartLoops: false)
    let adapter = TransportAdapter<AdapterJobTestState>(keeper: keeper, transport: transport, landID: "adapter-job")
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return Fixture(keeper: keeper, adapter: adapter, transport: transport)
}

/// Runs `work`, recording an issue if it doesn't finish within 10 s (a backstop against a
/// broken build hanging the run; the interleavings themselves are forced by gates). Built on
/// `raceDeadline`: `work` runs in its own task, so one stuck past the deadline is left behind
/// instead of hanging the test, as a task group would.
@discardableResult
private func bounded<T: Sendable>(
    _ step: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T? {
    switch await raceDeadline(.seconds(10), work) {
    case .finished(let result):
        return try result.get()
    case .timedOut:
        Issue.record("Timed out: \(step)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Sends, bounded: the send returns while the action's resolver is held, because the inbound
/// chain isn't blocked by it.
private func sendReturning(_ f: Fixture, _ requestID: String, _ action: some ActionPayload & Sendable, from session: SessionID) async throws {
    try await bounded("the send of \(requestID) returns while its resolver is held") {
        try await f.send(requestID, action, from: session)
    }
}

@Suite("Adapter: actions with resolvers don't block the session's chain (tick lands)", .timeLimit(.minutes(1)))
struct TransportAdapterActionJobTests {
    let s1 = SessionID("s1"), c1 = ClientID("c1")

    @Test("Two held actions answer in completion order, each under its own requestID; a resolver-free action overtakes both")
    func outOfOrderResponses() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = AdapterJobGates.freshKey(), b = AdapterJobGates.freshKey()
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        try await sendReturning(f, "B", AdapterJobHeldAction(key: b), from: s1)
        try await bounded("A's resolver") { await AdapterJobGates.gate(a).waitUntilArrived() }
        try await bounded("B's resolver") { await AdapterJobGates.gate(b).waitUntilArrived() }
        try await f.send("C", AdapterJobPlainAction(amount: 1), from: s1)
        #expect(await f.answers(for: s1) == ["C"])

        AdapterJobGates.gate(b).open()
        try await bounded("B's answer") { await f.adapter.waitForActionResponsesFinishedForTesting(1) }
        #expect(await f.answers(for: s1) == ["C", "B"])
        AdapterJobGates.gate(a).open()
        try await bounded("A's answer") { await f.adapter.waitForActionResponsesFinishedForTesting(2) }
        #expect(await f.answers(for: s1) == ["C", "B", "A"])
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 0)
        try await bounded("the keeper's jobs") { await f.keeper.waitForActionJobsForTesting() }
        #expect(await f.keeper.actionJobCountsForTesting().slots == 0)
    }

    @Test("A disconnect with held actions: nothing is sent to the session, no task stays tracked, the keeper's slots are read")
    func disconnectDropsPendingResponses() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = AdapterJobGates.freshKey(), b = AdapterJobGates.freshKey()
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        try await sendReturning(f, "B", AdapterJobHeldAction(key: b), from: s1)
        try await bounded("A's resolver") { await AdapterJobGates.gate(a).waitUntilArrived() }
        try await bounded("B's resolver") { await AdapterJobGates.gate(b).waitUntilArrived() }
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 2)
        let before = await f.answers(for: s1)

        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 0)
        // The leave rejected both jobs at once; their tasks read the rejections and drop them.
        try await bounded("both answers finish") { await f.adapter.waitForActionResponsesFinishedForTesting(2) }
        #expect(await f.answers(for: s1) == before, "no answer reaches the closed session")
        AdapterJobGates.gate(a).open()
        AdapterJobGates.gate(b).open()
        try await bounded("the keeper's jobs") { await f.keeper.waitForActionJobsForTesting() }
        #expect(await f.keeper.actionJobCountsForTesting() == (jobs: 0, slots: 0, started: 2))
    }

    @Test("An old connection's pending answer, held until the SessionID reconnected with a new pending action, is dropped")
    func staleAnswerAfterReconnect() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = AdapterJobGates.freshKey(), b = AdapterJobGates.freshKey()
        let answerHold = HeldGate()
        // Only the first answer (A's) is held.
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.actionResponse, arrival: 1) {
            await answerHold.arrive()
        }.hook)
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        try await bounded("A's resolver") { await AdapterJobGates.gate(a).waitUntilArrived() }
        let baseline = await f.answers(for: s1)

        // The disconnect's leave rejects A at once; A's answer reaches the hold.
        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        try await bounded("A's answer is held") { await answerHold.waitUntilArrived() }
        try await f.join(s1, c1, as: "p1")
        try await sendReturning(f, "B", AdapterJobHeldAction(key: b), from: s1)
        try await bounded("B's resolver") { await AdapterJobGates.gate(b).waitUntilArrived() }
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 1, "B's task is tracked")

        answerHold.open()
        try await bounded("A's answer finishes") { await f.adapter.waitForActionResponsesFinishedForTesting(1) }
        #expect(await f.answers(for: s1) == baseline, "the new connection gets no answer for A")
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 1, "B's task is still tracked")

        AdapterJobGates.gate(b).open()
        try await bounded("B's answer") { await f.adapter.waitForActionResponsesFinishedForTesting(2) }
        #expect(await f.answers(for: s1) == baseline + ["B"])
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 0)
        AdapterJobGates.gate(a).open()
        try await bounded("the keeper's jobs") { await f.keeper.waitForActionJobsForTesting() }
        #expect(await f.keeper.actionJobCountsForTesting().slots == 0)
    }

    @Test("A disconnect while submitAction returns a pending job: no task is tracked, nothing is sent, the slot is read")
    func disconnectDuringSubmitReturn() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = AdapterJobGates.freshKey()
        let submitted = HeldGate()
        await f.keeper.installHolds(HoldRegistry.at(.actionSubmitted) { await submitted.arrive() })
        let baseline = await f.answers(for: s1)
        let sending = Task { try await f.send("A", AdapterJobHeldAction(key: a), from: s1) }
        try await bounded("A's submit returns") { await submitted.waitUntilArrived() }

        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        submitted.open()
        try await bounded("the send") { try await sending.value }
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 0, "no task is tracked for the ended connection")
        try await bounded("A's answer finishes") { await f.adapter.waitForActionResponsesFinishedForTesting(1) }
        #expect(await f.answers(for: s1) == baseline)
        AdapterJobGates.gate(a).open()
        try await bounded("the keeper's jobs") { await f.keeper.waitForActionJobsForTesting() }
        #expect(await f.keeper.actionJobCountsForTesting() == (jobs: 0, slots: 0, started: 1))
    }

    @Test("An ACK or an intake error held on its way back from the keeper across a disconnect and a reconnect is dropped", arguments: [false, true])
    func staleIntakeAnswer(unregistered: Bool) async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let submitted = HeldGate()
        await f.keeper.installHolds(HoldRegistry.at(.actionSubmitted) { await submitted.arrive() })
        let baseline = await f.answers(for: s1)
        let sending = Task {
            if unregistered {
                try await f.send("C", AdapterJobUnregisteredAction(amount: 1), from: s1)
            } else {
                try await f.send("C", AdapterJobPlainAction(amount: 1), from: s1)
            }
        }
        try await bounded("C's submit returns") { await submitted.waitUntilArrived() }
        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        await f.keeper.installHolds(nil)
        try await f.join(s1, c1, as: "p1")
        let rejoined = await f.answers(for: s1)

        submitted.open()
        try await bounded("the send") { try await sending.value }
        #expect(await f.answers(for: s1) == rejoined, "the new connection gets no answer for C")
        #expect(rejoined == baseline)
    }
}
