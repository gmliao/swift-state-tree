// Tests/SwiftStateTreeTests/ReadOnlyHandlerOutputsTests.swift
//
// CanJoin and the sync handler get the state by value, and replay reruns neither. Their contexts
// were keyed on `lastCommittedTickId`, which no turn takes, so their events and sync requests
// stayed in the keeper's tables: never sent, never recorded, never freed (#66). Their scopes now
// drop and count every output, as the destroy handlers' do (#700 K2-E2, K2 plan §4.4).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ReadOnlyOutputsState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

@Payload
struct ReadOnlyOutputsAction: ActionPayload {
    typealias Response = ReadOnlyOutputsAck
    let amount: Int
}

@Payload
struct ReadOnlyOutputsAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct ReadOnlyOutputsEvent: ServerEventPayload {
    let from: String
}

/// Every handler that can emit does, and requests a sync: CanJoin (a refusal included), OnJoin,
/// an action, the tick handler on a tick land, and the sync handler.
private func readOnlyOutputsLand(tick: Bool) -> LandDefinition<ReadOnlyOutputsState> {
    Land("read-only-outputs", using: ReadOnlyOutputsState.self) {
        ServerEvents { Register(ReadOnlyOutputsEvent.self) }
        Rules {
            CanJoin { _, session, ctx in
                ctx.emitEvent(ReadOnlyOutputsEvent(from: "canJoin"), to: .all)
                ctx.requestSyncNow()
                if session.playerID == "refused" { throw JoinError.roomIsFull }
                return .allow(playerID: PlayerID(session.playerID))
            }
            OnJoin { _, ctx in
                ctx.emitEvent(ReadOnlyOutputsEvent(from: "onJoin"), to: .all)
                ctx.requestSyncBroadcastOnly()
            }
            HandleAction(ReadOnlyOutputsAction.self) { _, _, ctx in
                ctx.emitEvent(ReadOnlyOutputsEvent(from: "action"), to: .all)
                ctx.requestSyncNow()
                return ReadOnlyOutputsAck(ok: true)
            }
        }
        if tick {
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in
                    state.ticks += 1
                    ctx.emitEvent(ReadOnlyOutputsEvent(from: "tick"), to: .all)
                    ctx.requestSyncBroadcastOnly()
                }
                StateSync(every: .seconds(3600)) { _, ctx in
                    ctx.emitEvent(ReadOnlyOutputsEvent(from: "syncHandler"), to: .all)
                    ctx.requestSyncNow()
                }
            }
        } else {
            Lifetime {
                StateSync(every: .seconds(3600)) { _, ctx in
                    ctx.emitEvent(ReadOnlyOutputsEvent(from: "syncHandler"), to: .all)
                    ctx.requestSyncNow()
                }
            }
        }
    }
}

/// What a recorded run left behind.
private struct ReadOnlyOutputsRun {
    let keeper: LandKeeper<ReadOnlyOutputsState>
    let recorder: ReevaluationRecorder
    /// The keys left in the sync-request and emitted-event tables after each call.
    let keysAfter: [(step: String, syncRequestTicks: [Int64], eventTicks: [Int64])]
}

/// P-K2E-1's run (`Notes/plans/2026-11-26-k2-probe-k2e1.swift`), on a tick or a tickless land:
/// a join, a refused join, an action, a tick, a sync loop iteration, a second join, a tick.
private func runReadOnlyOutputs(tick: Bool) async throws -> ReadOnlyOutputsRun {
    let landID = "read-only-outputs:\(UUID().uuidString)"
    let definition = readOnlyOutputsLand(tick: tick)
    let keeper = LandKeeper<ReadOnlyOutputsState>(
        definition: definition,
        initialState: ReadOnlyOutputsState(),
        enableLiveStateHashRecording: true,
        landID: landID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID, landType: definition.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), metadata: [:],
        landDefinitionID: definition.id, rngSeed: DeterministicSeed.fromLandID(landID),
        version: ReevaluationRecordVersion.current
    ))
    var keysAfter: [(step: String, syncRequestTicks: [Int64], eventTicks: [Int64])] = []
    func note(_ step: String) async {
        keysAfter.append((step, await keeper.syncRequestTicksForTesting(), await keeper.emittedEventTicksForTesting()))
    }
    func join(_ player: String, _ n: Int) async throws {
        _ = try await keeper.join(
            session: PlayerSession(playerID: player), clientID: ClientID("c\(n)"),
            sessionID: SessionID("s\(n)"), services: LandServices()
        )
    }
    try await join("p1", 1)
    await note("join p1")
    await #expect(throws: (any Error).self) { try await join("refused", 9) }
    await note("refused join")
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: ReadOnlyOutputsAction.self), payload: AnyCodable(ReadOnlyOutputsAction(amount: 1))),
        playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1")
    )
    await note("action")
    if tick {
        await keeper.stepTickOnce()
        await note("tick 0")
    }
    await keeper.runSyncLoopIterationForTesting()
    await note("sync")
    try await join("p2", 2)
    await note("join p2")
    if tick {
        await keeper.stepTickOnce()
        await note("tick 1")
    }
    await keeper.waitForRecorderSubmissionsForTesting()
    return ReadOnlyOutputsRun(keeper: keeper, recorder: recorder, keysAfter: keysAfter)
}

@Suite("CanJoin's and the sync handler's outputs are dropped and counted (#700 K2-E2)", .timeLimit(.minutes(1)))
struct ReadOnlyHandlerOutputsTests {
    @Test("no event or sync request is left in the keeper's tables after any call", arguments: [true, false])
    func noOutputIsStranded(tick: Bool) async throws {
        let run = try await runReadOnlyOutputs(tick: tick)
        for after in run.keysAfter {
            #expect(after.syncRequestTicks.isEmpty, "sync requests left after \(after.step): \(after.syncRequestTicks)")
            #expect(after.eventTicks.isEmpty, "events left after \(after.step): \(after.eventTicks)")
        }
        await run.keeper.forceShutdown()
    }

    @Test("each of CanJoin's and the sync handler's outputs is counted, and takes no sequence number", arguments: [true, false])
    func outputsAreCountedAndTakeNoNumber(tick: Bool) async throws {
        let run = try await runReadOnlyOutputs(tick: tick)
        // Three CanJoins (one refused) and one sync handler call, two outputs each.
        #expect(run.keeper.readOnlyHandlerOutputsDropped.count == 8)
        #expect(run.keeper.destroyHandlerOutputsDropped.count == 0)
        #expect(run.keeper.lateStepOutputs.count == 0)
        // Every number the run took is in the record: no gap is left where a dropped output was.
        let frames = await run.recorder.getAllFrames()
        let sequences = frames.flatMap { frame in
            frame.lifecycleEvents.map(\.sequence) + frame.actions.map(\.sequence) + frame.serverEvents.map(\.sequence)
        }.sorted()
        #expect(sequences == Array(0..<Int64(sequences.count)), "\(sequences)")
        await run.keeper.forceShutdown()
    }

    @Test("a run whose CanJoin and sync handler emit replays clean", arguments: [true, false])
    func recordReplaysClean(tick: Bool) async throws {
        let run = try await runReadOnlyOutputs(tick: tick)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("read-only-outputs-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await run.recorder.save(to: path)
        await run.keeper.forceShutdown()
        let result = try await ReevaluationEngine.run(
            definition: readOnlyOutputsLand(tick: tick),
            initialState: ReadOnlyOutputsState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty, "\(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed)
    }
}
