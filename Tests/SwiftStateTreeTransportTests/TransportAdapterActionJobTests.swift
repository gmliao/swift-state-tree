// Tests/SwiftStateTreeTransportTests/TransportAdapterActionJobTests.swift
//
// On a tick land, the adapter submits an action on the session's inbound chain and answers an
// action with resolvers from a tracked task, so the chain moves on while the resolvers run.
// Responses come in completion order, each under its own requestID. A disconnect drops the
// session's pending responses: nothing is sent to it, no task stays tracked, and the keeper's
// slots are read.

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

struct AdapterJobOutput: ResolverOutput {}

/// One gate per action key: resolvers are static, and parallel tests must not share a gate.
private enum AdapterJobGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [Int: TestGate] = [:]

    static func gate(_ key: Int) -> TestGate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            let gate = TestGate()
            gates[key] = gate
            return gate
        }
    }
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

/// Polls an async `condition` every 5 ms for up to 5 s; returns its final value.
private func pollUntilAsync(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Sends from a separate task and checks the send returns while the action's resolver is held:
/// the inbound chain isn't blocked by it.
private func sendReturning(_ f: Fixture, _ requestID: String, _ action: some ActionPayload, from session: SessionID) async throws {
    let returned = ReturnedFlag()
    let sending = Task {
        try await f.send(requestID, action, from: session)
        returned.set()
    }
    #expect(await pollUntilAsync { returned.isSet }, "the send of \(requestID) returns while its resolver is held")
    if returned.isSet { try await sending.value }
}

private final class ReturnedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Adapter: actions with resolvers don't block the session's chain (tick lands)", .timeLimit(.minutes(1)))
struct TransportAdapterActionJobTests {
    let s1 = SessionID("s1"), c1 = ClientID("c1")

    @Test("Two held actions answer in completion order, each under its own requestID; a resolver-free action overtakes both")
    func outOfOrderResponses() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = 3_001, b = 3_002
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        try await sendReturning(f, "B", AdapterJobHeldAction(key: b), from: s1)
        #expect(await AdapterJobGates.gate(a).waitForArrivals(1))
        #expect(await AdapterJobGates.gate(b).waitForArrivals(1))
        try await f.send("C", AdapterJobPlainAction(amount: 1), from: s1)
        #expect(await f.answers(for: s1) == ["C"])

        AdapterJobGates.gate(b).open()
        #expect(await pollUntilAsync { await f.answers(for: self.s1) == ["C", "B"] })
        AdapterJobGates.gate(a).open()
        #expect(await pollUntilAsync { await f.answers(for: self.s1) == ["C", "B", "A"] })
        #expect(await pollUntilAsync { await f.adapter.actionResponseTaskCountForTesting() == 0 })
        #expect(await f.keeper.actionJobCountsForTesting().slots == 0)
    }

    @Test("A disconnect with held actions: nothing is sent to the session, no task stays tracked, the keeper's slots are read")
    func disconnectDropsPendingResponses() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = 3_011, b = 3_012
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        try await sendReturning(f, "B", AdapterJobHeldAction(key: b), from: s1)
        #expect(await AdapterJobGates.gate(a).waitForArrivals(1))
        #expect(await AdapterJobGates.gate(b).waitForArrivals(1))
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 2)
        let before = await f.answers(for: s1)

        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        #expect(await f.adapter.actionResponseTaskCountForTesting() == 0)
        AdapterJobGates.gate(a).open()
        AdapterJobGates.gate(b).open()
        #expect(await pollUntilAsync { await f.keeper.actionJobCountsForTesting() == (jobs: 0, slots: 0, started: 2) })
        #expect(await f.answers(for: s1) == before, "no answer reaches the closed session")
    }

    @Test("A reconnect that reuses the SessionID gets no answer for the old connection's held actions")
    func reusedSessionIDGetsNoOldAnswer() async throws {
        let f = await makeFixture()
        try await f.join(s1, c1, as: "p1")
        let a = 3_021
        try await sendReturning(f, "A", AdapterJobHeldAction(key: a), from: s1)
        #expect(await AdapterJobGates.gate(a).waitForArrivals(1))
        await f.adapter.onDisconnect(sessionID: s1, clientID: c1)
        try await f.join(s1, c1, as: "p1")
        let before = await f.answers(for: s1)

        AdapterJobGates.gate(a).open()
        #expect(await pollUntilAsync { await f.keeper.actionJobCountsForTesting() == (jobs: 0, slots: 0, started: 1) })
        #expect(await pollUntilAsync { await f.adapter.actionResponseTaskCountForTesting() == 0 })
        try await f.send("C", AdapterJobPlainAction(amount: 1), from: s1)
        #expect(await f.answers(for: s1) == before + ["C"], "the new connection gets only its own answers")
    }
}
