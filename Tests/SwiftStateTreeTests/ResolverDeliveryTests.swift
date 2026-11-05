// Tests/SwiftStateTreeTests/ResolverDeliveryTests.swift
//
// An action's resolver result is a turn input: after the resolvers' await, only the delivery
// runs, and it validates the intake's ticket (the sender's entry generation) against the
// current state. A rejected delivery leaves a sequence gap that replay steps over.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct DeliveryTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct DeliveryGatedAction: ActionPayload {
    typealias Response = DeliveryAck
    /// Also the key of the action's resolver gate (`DeliveryGates`).
    let amount: Int
}

@Payload
struct DeliveryPlainAction: ActionPayload {
    typealias Response = DeliveryAck
    let amount: Int
}

@Payload
struct DeliveryAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct DeliveryEvent: ServerEventPayload {
    let amount: Int
}

struct DeliveryResolverOutput: ResolverOutput {
    let value: Int
}

/// One gate per test, keyed by the gated action's amount: resolvers are static, and a gate
/// shared by parallel tests would let one test release another's resolver.
enum DeliveryGates {
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

struct DeliveryGatedResolver: ContextResolver {
    typealias Output = DeliveryResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DeliveryResolverOutput {
        let amount = (ctx.actionPayload as? DeliveryGatedAction)?.amount ?? -1
        await DeliveryGates.gate(amount).enterAndWait()
        return DeliveryResolverOutput(value: amount)
    }
}

private func makeDeliveryDefinition(tick: Bool) -> LandDefinition<DeliveryTestState> {
    if tick {
        return Land("delivery-test", using: DeliveryTestState.self) {
            ServerEvents { Register(DeliveryEvent.self) }
            Rules {
                // OnLeave makes a leave a lifecycle input; on the legacy tick path its tick
                // awaits the broadcast sync before W2.
                OnLeave { (_: inout DeliveryTestState, _: LandContext) in }
                HandleAction(DeliveryGatedAction.self, resolvers: DeliveryGatedResolver.self) {
                    (state: inout DeliveryTestState, action: DeliveryGatedAction, ctx: LandContext) in
                    state.total += action.amount
                    ctx.emitEvent(DeliveryEvent(amount: action.amount), to: .all)
                    return DeliveryAck(ok: true)
                }
                HandleAction(DeliveryPlainAction.self) {
                    (state: inout DeliveryTestState, action: DeliveryPlainAction, ctx: LandContext) in
                    state.total += action.amount
                    ctx.emitEvent(DeliveryEvent(amount: action.amount), to: .all)
                    return DeliveryAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout DeliveryTestState, _: LandContext) in
                    state.ticks += 1
                }
            }
        }
    }
    return Land("delivery-test", using: DeliveryTestState.self) {
        ServerEvents { Register(DeliveryEvent.self) }
        Rules {
            HandleAction(DeliveryGatedAction.self, resolvers: DeliveryGatedResolver.self) {
                (state: inout DeliveryTestState, action: DeliveryGatedAction, _: LandContext) in
                state.total += action.amount
                return DeliveryAck(ok: true)
            }
            HandleAction(DeliveryPlainAction.self) {
                (state: inout DeliveryTestState, action: DeliveryPlainAction, _: LandContext) in
                state.total += action.amount
                return DeliveryAck(ok: true)
            }
        }
    }
}

private let deliveryLandID = "delivery-test:local"

/// Reports in-turn sync for every keeper and commits each requested sync phase, so a keeper
/// attached to it takes the in-turn path (`usesInTurnSync`) whatever `IN_TURN_SYNC` says. Not an
/// actor: its synchronous calls need no isolation.
private final class InTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

private func makeDeliveryKeeper(tick: Bool, inTurn: Bool = false) async -> LandKeeper<DeliveryTestState> {
    let keeper = LandKeeper<DeliveryTestState>(
        definition: makeDeliveryDefinition(tick: tick),
        initialState: DeliveryTestState(),
        enableLiveStateHashRecording: tick,
        autoStartLoops: false,
        transport: inTurn ? InTurnTransport() : nil
    )
    await keeper.setLandID(deliveryLandID)
    if tick, let recorder = await keeper.getReevaluationRecorder() {
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: deliveryLandID,
            landType: "delivery-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "delivery-test",
            rngSeed: DeterministicSeed.fromLandID(deliveryLandID),
            version: "2.0"
        ))
    }
    return keeper
}

private func gated(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: DeliveryGatedAction.self),
        payload: AnyCodable(DeliveryGatedAction(amount: amount))
    )
}

private func plain(_ amount: Int) -> ActionEnvelope {
    ActionEnvelope(
        typeIdentifier: String(describing: DeliveryPlainAction.self),
        payload: AnyCodable(DeliveryPlainAction(amount: amount))
    )
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

/// Sends a gated action from p1 and returns once its resolver holds (its sequence is taken).
private func sendHeld(
    _ keeper: LandKeeper<DeliveryTestState>,
    amount: Int
) async -> Task<AnyCodable, Error> {
    let task = Task {
        try await keeper.handleActionEnvelope(gated(amount), playerID: p1, clientID: c1, sessionID: s1)
    }
    await DeliveryGates.gate(amount).waitUntilEntered()
    return task
}

/// Gate key for one combination of a parameterized test, so parallel cases never share a gate.
private func gateKey(_ base: Int, tick: Bool, inTurn: Bool) -> Int {
    base + (tick ? 0 : 1) + (inTurn ? 10 : 0)
}

/// An accepted action's response: a tick land acknowledges at once (the handler runs in a
/// tick); a tickless land returns the handler's response from the input's turn.
private func expectDelivered(_ response: AnyCodable, tick: Bool) {
    if tick {
        #expect(response.base is Void)
    } else {
        let ack = (response.base as? DeliveryAck) ?? ((response.base as? AnyCodable)?.base as? DeliveryAck)
        #expect(ack?.ok == true, "unexpected response: \(response.base)")
    }
}

private func expectSenderSuperseded(_ task: Task<AnyCodable, Error>) async {
    do {
        _ = try await task.value
        Issue.record("Expected the delivery to be rejected")
    } catch let rejection as LandInputRejection {
        #expect(rejection == .senderSuperseded)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func recordedSequenceGaps(_ frames: [ReevaluationTickFrame]) -> [Int64] {
    let recorded = Set(frames.flatMap { frame in
        frame.actions.map(\.sequence)
            + frame.clientEvents.map(\.sequence)
            + frame.lifecycleEvents.map(\.sequence)
            + frame.serverEvents.map(\.sequence)
    })
    guard let highest = recorded.max() else { return [] }
    return (0...highest).filter { !recorded.contains($0) }
}

/// Records sent events; the next send after `arm()` holds on `gate` until released, which
/// suspends a live tick in its output flush (after its watermarks).
private actor HoldingTransport: LandKeeperTransport {
    let gate = WatermarkGate()
    private var armed = false

    func arm() { armed = true }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        if armed {
            armed = false
            await gate.enterAndWait()
        }
    }

    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
}

/// Holds the next `syncBroadcastOnlyFromTransport` after `arm()`. On the legacy tick path an
/// applied OnLeave awaits it inside `processPendingActions`, between the tick's W1 and W2.
private actor BroadcastHoldingTransport: LandKeeperTransport {
    let gate = WatermarkGate()
    private var armed = false

    func arm() { armed = true }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {
        if armed {
            armed = false
            await gate.enterAndWait()
        }
    }
    func onLandDestroyed() async {}
}

@Suite("Resolver result delivered as a validated input", .timeLimit(.minutes(1)))
struct ResolverDeliveryTests {
    @Test("The sender leaves while its action's resolvers run: the delivery is rejected", arguments: [true, false], [false, true])
    func senderLeavesDuringResolvers(tick: Bool, inTurn: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick, inTurn: inTurn)
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = gateKey(101, tick: tick, inTurn: inTurn)
        let held = await sendHeld(keeper, amount: amount)

        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        await expectSenderSuperseded(held)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("The sender's entry is replaced by a re-join with the same client and session: the delivery is rejected", arguments: [true, false], [false, true])
    func senderEntryReplacedDuringResolvers(tick: Bool, inTurn: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick, inTurn: inTurn)
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = gateKey(201, tick: tick, inTurn: inTurn)
        let held = await sendHeld(keeper, amount: amount)

        // Same player, client and session: only the entry's generation tells them apart.
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        await expectSenderSuperseded(held)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("The sender's entry is unchanged: the action is delivered and applied", arguments: [true, false], [false, true])
    func senderUnchangedIsDelivered(tick: Bool, inTurn: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick, inTurn: inTurn)
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = gateKey(301, tick: tick, inTurn: inTurn)
        let held = await sendHeld(keeper, amount: amount)

        // Other players come and go meanwhile.
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        DeliveryGates.gate(amount).release()
        expectDelivered(try await held.value, tick: tick)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == amount)
    }

    @Test("A sender with no entry at intake (a direct caller) is delivered even if a join happens meanwhile", arguments: [true, false], [false, true])
    func noEntryAtIntakeIsDelivered(tick: Bool, inTurn: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick, inTurn: inTurn)
        #expect(await keeper.isUsingInTurnSync() == inTurn)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = gateKey(401, tick: tick, inTurn: inTurn)
        let held = await sendHeld(keeper, amount: amount)

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        expectDelivered(try await held.value, tick: tick)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == amount)
    }

    @Test("Tick land: a delivery rejected between ticks leaves one sequence gap; replay matches")
    func rejectedDeliveryReplayMatches() async throws {
        let keeper = await makeDeliveryKeeper(tick: true)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-rejected-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        _ = try await keeper.handleActionEnvelope(plain(1), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()

        let held = await sendHeld(keeper, amount: 501)
        // Inputs and ticks continue while the resolver holds.
        _ = try await keeper.handleActionEnvelope(plain(2), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        DeliveryGates.gate(501).release()
        await expectSenderSuperseded(held)

        _ = try await keeper.handleActionEnvelope(plain(3), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 6)

        let recorder = try #require(await keeper.getReevaluationRecorder())
        #expect(recordedSequenceGaps(await recorder.getAllFrames()).count == 1)
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    @Test("Tick land: a late delivery and a rejected delivery (after a re-join) in one run; replay matches")
    func rejectedDeliveryAndDeliveredLateResolverReplayMatch() async throws {
        let keeper = await makeDeliveryKeeper(tick: true)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-mixed-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()

        // Two held actions from p1; the first is delivered after ticks, the second is rejected
        // because p1 re-joins (a new entry generation) before it resolves.
        let delivered = await sendHeld(keeper, amount: 601)
        _ = try await keeper.handleActionEnvelope(plain(5), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        DeliveryGates.gate(601).release()
        _ = try await delivered.value

        let rejected = await sendHeld(keeper, amount: 602)
        await keeper.stepTickOnce()
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(plain(7), playerID: p2, clientID: c2, sessionID: s2)
        DeliveryGates.gate(602).release()
        await expectSenderSuperseded(rejected)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 601 + 5 + 7)

        let recorder = try #require(await keeper.getReevaluationRecorder())
        #expect(recordedSequenceGaps(await recorder.getAllFrames()).count == 1)
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    @Test("Tick land: a delivery rejected after taking its number inside a tick's W1–W2 window; replay matches")
    func rejectedDeliveryNumberedInsideW1W2ReplayMatches() async throws {
        let transport = BroadcastHoldingTransport()
        let keeper = LandKeeper<DeliveryTestState>(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            transport: transport
        )
        await keeper.setLandID(deliveryLandID)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: deliveryLandID,
            landType: "delivery-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "delivery-test",
            rngSeed: DeterministicSeed.fromLandID(deliveryLandID),
            version: "2.0"
        ))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-w1w2-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let p3 = PlayerID("p3"), c3 = ClientID("c3"), s3 = SessionID("s3")
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        try await keeper.join(playerID: p3, clientID: c3, sessionID: s3)
        await keeper.stepTickOnce()

        // p3's OnLeave is applied in tick 1, whose broadcast sync then holds before W2; p1's
        // gated action takes its number there.
        try await keeper.leave(playerID: p3, clientID: c3, sessionID: s3)
        await transport.arm()
        let suspendedTick = Task { await keeper.stepTickOnce() }
        await transport.gate.waitUntilEntered()
        let held = await sendHeld(keeper, amount: 801)
        transport.gate.release()
        await suspendedTick.value

        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(801).release()
        await expectSenderSuperseded(held)
        _ = try await keeper.handleActionEnvelope(plain(4), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 4)

        let frames = await recorder.getAllFrames()
        let gaps = recordedSequenceGaps(frames)
        #expect(gaps.count == 1)
        let tick1 = try #require(frames.first { $0.tickId == 1 })
        if let gap = gaps.first, let w1 = tick1.sequenceBeforeInputs, let w2 = tick1.sequenceBeforeTickHandler {
            #expect(gap >= w1)
            #expect(gap < w2)
        } else {
            Issue.record("Expected one gap and both of tick 1's watermarks")
        }
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }

    @Test("Tick land: a delivery rejected after taking its number while a tick was suspended past its watermarks; replay matches")
    func rejectedDeliveryNumberedMidTickReplayMatches() async throws {
        let transport = HoldingTransport()
        let keeper = LandKeeper<DeliveryTestState>(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            transport: transport
        )
        await keeper.setLandID(deliveryLandID)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: deliveryLandID,
            landType: "delivery-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "delivery-test",
            rngSeed: DeterministicSeed.fromLandID(deliveryLandID),
            version: "2.0"
        ))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-midtick-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()

        // Tick 1 applies p2's action and suspends in its event send; p1's gated action takes
        // its number then, between tick 1's watermarks and tick 2's.
        _ = try await keeper.handleActionEnvelope(plain(1), playerID: p2, clientID: c2, sessionID: s2)
        await transport.arm()
        let suspendedTick = Task { await keeper.stepTickOnce() }
        await transport.gate.waitUntilEntered()
        let held = await sendHeld(keeper, amount: 701)
        transport.gate.release()
        await suspendedTick.value

        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(701).release()
        await expectSenderSuperseded(held)
        _ = try await keeper.handleActionEnvelope(plain(2), playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 3)

        let frames = await recorder.getAllFrames()
        let gaps = recordedSequenceGaps(frames)
        #expect(gaps.count == 1)
        let tick1 = try #require(frames.first { $0.tickId == 1 })
        let tick2 = try #require(frames.first { $0.tickId == 2 })
        // A watermark is the next number to take; tick 1's handler emits nothing, so the first
        // number taken after its W2 is W2 itself.
        if let gap = gaps.first, let w2 = tick1.sequenceBeforeTickHandler, let w1 = tick2.sequenceBeforeInputs {
            #expect(gap >= w2)
            #expect(gap < w1)
        } else {
            Issue.record("Expected one gap and both watermarks")
        }
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeDeliveryDefinition(tick: true),
            initialState: DeliveryTestState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.tickHashes == result.recordedStateHashes)
    }
}
