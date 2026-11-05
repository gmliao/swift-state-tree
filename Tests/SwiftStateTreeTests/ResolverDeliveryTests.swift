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

private func makeDeliveryKeeper(tick: Bool) async -> LandKeeper<DeliveryTestState> {
    let keeper = LandKeeper<DeliveryTestState>(
        definition: makeDeliveryDefinition(tick: tick),
        initialState: DeliveryTestState(),
        enableLiveStateHashRecording: tick,
        autoStartLoops: false
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

@Suite("Resolver result delivered as a validated input")
struct ResolverDeliveryTests {
    @Test("The sender leaves while its action's resolvers run: the delivery is rejected", arguments: [true, false])
    func senderLeavesDuringResolvers(tick: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = tick ? 101 : 102
        let held = await sendHeld(keeper, amount: amount)

        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        await expectSenderSuperseded(held)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("The sender's entry is replaced by a re-join with the same client and session: the delivery is rejected", arguments: [true, false])
    func senderEntryReplacedDuringResolvers(tick: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = tick ? 201 : 202
        let held = await sendHeld(keeper, amount: amount)

        // Same player, client and session: only the entry's generation tells them apart.
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        await expectSenderSuperseded(held)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 0)
    }

    @Test("The sender's entry is unchanged: the action is delivered and applied", arguments: [true, false])
    func senderUnchangedIsDelivered(tick: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let amount = tick ? 301 : 302
        let held = await sendHeld(keeper, amount: amount)

        // Other players come and go meanwhile.
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        DeliveryGates.gate(amount).release()
        _ = try await held.value
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == amount)
    }

    @Test("A sender with no entry at intake (a direct caller) is delivered even if a join happens meanwhile", arguments: [true, false])
    func noEntryAtIntakeIsDelivered(tick: Bool) async throws {
        let keeper = await makeDeliveryKeeper(tick: tick)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let amount = tick ? 401 : 402
        let held = await sendHeld(keeper, amount: amount)

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        DeliveryGates.gate(amount).release()
        _ = try await held.value
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
