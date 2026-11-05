// Tests/SwiftStateTreeTransportTests/LandKeeperInputTurnTests.swift
//
// In-turn sync on tickless lands: every entry point (action, client event, join, leave) runs as an
// input turn. One drain at a time, an ordered snapshot of at most `inputTurnBatchLimit` ready
// inputs per turn, per-input responses, the legacy throw semantics, and the sync-only turns that
// repair a failed plan or retry a deferred one.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Land

@StateNodeBuilder
struct InputTurnTestState: StateNodeProtocol {
    @Sync(.broadcast) var total: Int = 0
    @Sync(.broadcast) var joined: Int = 0
    @Sync(.broadcast) var initialized: Int = 0
    init() {}
}

@Payload
struct InputTurnEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

/// Adds `amount`; `sync` requests a sync phase. A negative amount is added, then throws (a
/// partial write before the throw).
@Payload
struct InputTurnAddAction: ActionPayload {
    typealias Response = InputTurnAddResponse
    let amount: Int
    let sync: Bool
}

@Payload
struct InputTurnAddResponse: ResponsePayload {
    let amount: Int
}

@Payload
struct InputTurnBumpEvent: ClientEventPayload {
    let amount: Int
}

struct InputTurnHandlerError: Error {}

private func makeInputTurnLand() -> LandDefinition<InputTurnTestState> {
    Land("input-turn-test", using: InputTurnTestState.self) {
        ServerEvents { Register(InputTurnEvent.self) }
        ClientEvents { Register(InputTurnBumpEvent.self) }
        Lifetime {
            OnInitialize { (state: inout InputTurnTestState, _: LandContext) in
                state.initialized = 1
            }
        }
        Rules {
            OnJoin { (state: inout InputTurnTestState, _: LandContext) in
                state.joined += 1
            }
            OnLeave { (state: inout InputTurnTestState, _: LandContext) in
                state.joined -= 1
            }
            HandleAction(InputTurnAddAction.self) { (state: inout InputTurnTestState, action: InputTurnAddAction, ctx: LandContext) in
                state.total += action.amount
                if action.amount < 0 {
                    throw InputTurnHandlerError()
                }
                ctx.emitEvent(InputTurnEvent(message: "added-\(action.amount)"), to: .all)
                if action.sync {
                    ctx.requestSyncNow()
                }
                return InputTurnAddResponse(amount: action.amount)
            }
            HandleEvent(InputTurnBumpEvent.self) { (state: inout InputTurnTestState, event: InputTurnBumpEvent, _: LandContext) in
                state.total += event.amount
            }
        }
    }
}

// MARK: - Helpers

/// Records frames per session.
private actor InputTurnTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            sent.append((target, data))
        }
    }

    /// Frames for `sessionID`, as UTF-8 text (JSON encoding).
    func texts(for sessionID: SessionID) -> [String] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return String(decoding: entry.data, as: UTF8.self) }
            return nil
        }
    }
}

/// An ordered, thread-safe log.
private final class InputTurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Sizes of the input turns' batches, in turn order.
    var batchSizes: [Int] {
        snapshot.compactMap { $0.hasPrefix("input-batch-") ? Int($0.dropFirst("input-batch-".count)) : nil }
    }
}

/// A thread-safe switch.
private final class InputTurnSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

private struct InputTurnFixture {
    let keeper: LandKeeper<InputTurnTestState>
    let adapter: TransportAdapter<InputTurnTestState>
    let transport: InputTurnTransport
    let log = InputTurnLog()
    let session = SessionID("input-turn-session")
    let client = ClientID("input-turn-client")
    let player = PlayerID("input-turn-player")

    static func make(inTurn: Bool = true, recording: Bool = false) async throws -> InputTurnFixture {
        let transport = InputTurnTransport()
        let keeper = LandKeeper<InputTurnTestState>(
            definition: makeInputTurnLand(),
            initialState: InputTurnTestState(),
            enableLiveStateHashRecording: recording,
            autoStartLoops: false
        )
        let adapter = TransportAdapter<InputTurnTestState>(
            keeper: keeper,
            transport: transport,
            landID: "input-turn-test",
            inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let fixture = InputTurnFixture(keeper: keeper, adapter: adapter, transport: transport)
        let log = fixture.log
        await keeper.setInTurnProbeForTesting { log.append($0) }
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: fixture.client,
            playerID: fixture.player
        )
        #expect(await adapter.waitForOutboundDrain())
        return fixture
    }

    @discardableResult
    func add(_ amount: Int, sync: Bool = false) async throws -> Int? {
        let response = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: InputTurnAddAction.self),
                payload: AnyCodable(InputTurnAddAction(amount: amount, sync: sync))
            ),
            playerID: player,
            clientID: client,
            sessionID: session
        )
        return (response.base as? InputTurnAddResponse)?.amount
    }

    /// Waits until a frame after the first `after` frames for the session contains `text`.
    func waitForFrame(containing text: String, after: Int = 0, timeout: Duration = .seconds(2)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await transport.texts(for: session).dropFirst(after).contains(where: { $0.contains(text) }) { return true }
            try await safeTaskSleep(for: .milliseconds(5))
        }
        return false
    }
}

// MARK: - Tests

@Suite("In-turn sync: tickless input turns", .timeLimit(.minutes(1)))
struct LandKeeperInputTurnTests {

    @Test("concurrent actions: each caller gets its own input's response")
    func perInputResponses() async throws {
        let f = try await InputTurnFixture.make()
        let results = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
            for amount in 1...20 {
                group.addTask { (amount, try await f.add(amount)) }
            }
            var collected: [(Int, Int?)] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 20)
        #expect(results.allSatisfy { $0.0 == $0.1 }, "responses: \(results)")
        #expect(await f.keeper.currentState().total == (1...20).reduce(0, +))
    }

    @Test("batching: every input turn applies at most inputTurnBatchLimit inputs; all inputs run once")
    func batchesAreBounded() async throws {
        let f = try await InputTurnFixture.make()
        let count = 150
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask { try await f.add(1) }
            }
            try await group.waitForAll()
        }
        let sizes = f.log.batchSizes
        let limit = LandKeeper<InputTurnTestState>.inputTurnBatchLimit
        #expect(sizes.allSatisfy { $0 >= 1 && $0 <= limit }, "batch sizes: \(sizes)")
        #expect(sizes.reduce(0, +) == count + 1, "the join plus every action, once: \(sizes)")
        #expect(await f.keeper.currentState().total == count)
        #expect(await f.keeper.pendingItemSequencesForTesting().isEmpty)
    }

    @Test("an input arriving during a turn runs in the next turn")
    func arrivalDuringTurnGoesToNextTurn() async throws {
        let f = try await InputTurnFixture.make()
        let spawned = InputTurnSwitch()
        let late = InputTurnSwitch()
        let log = f.log
        await f.keeper.setInTurnProbeForTesting { label in
            log.append(label)
            guard label == "turn-begin", !spawned.isOn else { return }
            spawned.set(true)
            Task {
                _ = try? await f.add(99)
                late.set(true)
            }
            usleep(5_000)  // the task enqueues its job while this turn runs
        }
        let batchesBefore = f.log.batchSizes.count
        try await f.add(1)
        for _ in 0..<400 where !late.isOn {
            try await safeTaskSleep(for: .milliseconds(5))
        }
        #expect(late.isOn)
        let sizes = Array(f.log.batchSizes.dropFirst(batchesBefore))
        #expect(sizes == [1, 1], "the late input ran in its own, later turn: \(sizes)")
        #expect(await f.keeper.currentState().total == 100)
    }

    @Test("every tickless entry point runs as an input turn: join, action, client event, leave")
    func everyEntryPointIsATurn() async throws {
        let f = try await InputTurnFixture.make()
        #expect(await f.keeper.currentState().initialized == 1, "OnInitialize ran")
        #expect(await f.keeper.currentState().joined == 1)
        #expect(f.log.batchSizes == [1], "the join was a turn: \(f.log.snapshot)")

        try await f.add(2)
        try await f.keeper.handleClientEvent(
            AnyClientEvent(InputTurnBumpEvent(amount: 3)),
            playerID: f.player,
            clientID: f.client,
            sessionID: f.session
        )
        for _ in 0..<400 where await f.keeper.currentState().total != 5 {
            try await safeTaskSleep(for: .milliseconds(5))
        }
        #expect(await f.keeper.currentState().total == 5)
        try await f.keeper.leave(playerID: f.player, clientID: f.client)
        #expect(await f.keeper.currentState().joined == 0)
        #expect(f.log.batchSizes.count == 4, "join, action, client event, leave: \(f.log.snapshot)")
    }

    @Test("a throwing handler keeps the legacy semantics: same error, pending set and state, ON vs OFF")
    func throwSemanticsMatchLegacy() async throws {
        var outcomes: [(errors: Int, pending: [Int64], total: Int)] = []
        for inTurn in [true, false] {
            let f = try await InputTurnFixture.make(inTurn: inTurn)
            var errors = 0
            try await f.add(1)
            do { try await f.add(-5) } catch { errors += 1 }  // partial write, then throw
            do { try await f.add(2) } catch { errors += 1 }   // the pending -5 runs again and throws
            outcomes.append((errors, await f.keeper.pendingItemSequencesForTesting(), await f.keeper.currentState().total))
        }
        let on = outcomes[0], off = outcomes[1]
        #expect(on.errors == off.errors, "errors ON \(on.errors) vs OFF \(off.errors)")
        #expect(on.pending == off.pending, "pending ON \(on.pending) vs OFF \(off.pending)")
        #expect(on.total == off.total, "state ON \(on.total) vs OFF \(off.total)")
        #expect(on.pending.count == 2, "the throwing input and the one behind it stay pending")
    }

    @Test("failure repair: a failed in-turn plan on a tickless land is repaired by one sync-only turn")
    func failedPlanIsRepairedByASyncOnlyTurn() async throws {
        let f = try await InputTurnFixture.make()
        let failOnce = InputTurnSwitch()
        failOnce.set(true)
        await f.adapter.setSyncPlanFaultForTesting {
            if failOnce.isOn {
                failOnce.set(false)
                throw InputTurnHandlerError()
            }
        }
        let before = await f.transport.texts(for: f.session).count
        try await f.add(7, sync: true)
        #expect(await f.adapter.syncFailedPlans == 1)
        #expect(try await f.waitForFrame(containing: "/total", after: before), "the repair turn sent the state")
        #expect(await f.keeper.inTurnRepairTurns == 1)
    }

    @Test("freeze and resume interleaved with a deferred writer retry: the change still goes out once")
    func freezeResumeWithDeferredRetry() async throws {
        let f = try await InputTurnFixture.make()
        let pressured = InputTurnSwitch()
        pressured.set(true)
        await f.adapter.setWriterBackPressureOverrideForTesting { pressured.isOn }
        try await f.add(4, sync: true)
        #expect(await f.keeper.inTurnDeferredTurns == 1, "deferred; one retry waits for the drain")

        let freeze = try await f.adapter.debugFreeze()
        pressured.set(false)  // the retry runs while frozen: skipped, deferred to resume
        try await safeTaskSleep(for: .milliseconds(50))
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(try await f.waitForFrame(containing: "added-4"), "the deferred event went out")
        let texts = await f.transport.texts(for: f.session)
        #expect(texts.filter { $0.contains("added-4") }.count == 1, "once: \(texts)")
        #expect(await f.adapter.waitForOutboundDrain())
    }

    @Test("recorder: several drains in one tick merge into that tick's frame without overwriting events")
    func drainsInOneTickMerge() async throws {
        let f = try await InputTurnFixture.make(recording: true)
        try await f.add(1)
        try await f.add(2)
        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        #expect(Set(frames.map(\.tickId)).count == frames.count, "one frame per tick: \(frames.map(\.tickId))")
        let actions = frames.flatMap(\.actions).map(\.sequence)
        let events = frames.flatMap(\.serverEvents).map(\.typeIdentifier)
        #expect(actions.count == 2)
        #expect(events.count == 2, "both drains' server events kept: \(events)")
    }
}
