// Tests/SwiftStateTreeTests/StepScopeTests.swift
//
// A handler call's scope (#700 K2-E): outputs made through the call's context pass while the
// call runs; one made through a context kept past its call is dropped and counted.

import Foundation
import Synchronization
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct StepScopeState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    init() {}
}

@Payload
struct StepScopeNotice: ServerEventPayload {
    let n: Int
}

/// Events a transport was handed, by their payload's `n`.
private final class SentEvents: LandKeeperTransport {
    private let sent = Mutex<[Int]>([])
    var values: [Int] { sent.withLock { $0 } }
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        guard let notice = event.wireForm as? StepScopeNotice else { return }
        sent.withLock { $0.append(notice.n) }
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        let values = events.compactMap { ($0.event.wireForm as? StepScopeNotice)?.n }
        sent.withLock { $0.append(contentsOf: values) }
        return InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// The context each handler call was given, kept past the call.
private final class KeptContexts: Sendable {
    private let contexts = Mutex<[LandContext]>([])
    func keep(_ ctx: LandContext) { contexts.withLock { $0.append(ctx) } }
    var last: LandContext? { contexts.withLock { $0.last } }
}

@Suite("A handler call's scope gates its context's outputs (#700 K2-E)")
struct StepScopeTests {
    private func scope(asserts: Bool = false) -> (StepScope, LateStepOutputCounter) {
        let late = LateStepOutputCounter()
        return (StepScope(random: DeterministicRngService(seed: 1), late: late, assertsOnLateOutput: asserts), late)
    }

    @Test("An output passes while the scope is open, and is dropped and counted after the close")
    func passesUntilClosed() {
        let (scope, late) = scope()
        let ran = Mutex(0)
        scope.pass { ran.withLock { $0 += 1 } }
        #expect(ran.withLock { $0 } == 1)
        #expect(late.count == 0)

        scope.close()
        scope.pass { ran.withLock { $0 += 1 } }
        #expect(ran.withLock { $0 } == 1, "the output after the close didn't run")
        #expect(late.count == 1)
    }

    @Test("A context kept past its tick handler call drops its emit and its sync requests")
    func keptContextIsDropped() async throws {
        let kept = KeptContexts()
        let definition = Land("step-scope", using: StepScopeState.self) {
            ServerEvents { Register(StepScopeNotice.self) }
            Lifetime {
                Tick(every: .seconds(3600)) { state, ctx in
                    state.ticks += 1
                    kept.keep(ctx)
                    ctx.emitEvent(StepScopeNotice(n: state.ticks), to: .all)
                }
            }
        }
        let keeper = LandKeeper<StepScopeState>(definition: definition, initialState: StepScopeState(), enableLiveStateHashRecording: true, autoStartLoops: false, landID: "step-scope:kept")
        await keeper.awaitInitialization()
        await keeper.setLateStepOutputAssertsForTesting(false)
        await keeper.stepTickOnce()
        #expect(keeper.lateStepOutputs.count == 0, "the emit inside the call passed")
        let recorded = try #require(await keeper.getReevaluationRecorder()?.getAllFrames())
        #expect(recorded.flatMap(\.serverEvents).map(\.typeIdentifier) == ["StepScopeNotice"], "the in-call emit landed")

        let ctx = try #require(kept.last)
        let eventsBefore = await keeper.emittedEventTicksForTesting()
        let syncsBefore = await keeper.syncRequestTicksForTesting()
        ctx.emitEvent(StepScopeNotice(n: -1), to: .all)
        ctx.requestSyncNow()
        ctx.requestSyncBroadcastOnly()

        #expect(keeper.lateStepOutputs.count == 3)
        #expect(await keeper.emittedEventTicksForTesting() == eventsBefore, "the late emit reached no list")
        #expect(await keeper.syncRequestTicksForTesting() == syncsBefore, "the late sync requests reached no table")
    }

    @Test("The sync handler's context passes its outputs in the call and drops them once kept past it")
    func syncHandlerContextIsScoped() async throws {
        let kept = KeptContexts()
        let definition = Land("step-scope-sync", using: StepScopeState.self) {
            ServerEvents { Register(StepScopeNotice.self) }
            Lifetime {
                Tick(every: .seconds(3600)) { state, _ in state.ticks += 1 }
                StateSync(every: .seconds(3600)) { _, ctx in
                    kept.keep(ctx)
                    ctx.emitEvent(StepScopeNotice(n: 1), to: .all)
                    ctx.requestSyncNow()
                }
            }
        }
        let keeper = LandKeeper<StepScopeState>(definition: definition, initialState: StepScopeState(), landID: "step-scope:sync")
        await keeper.awaitInitialization()
        await keeper.setLateStepOutputAssertsForTesting(false)
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()
        let eventsBefore = await keeper.emittedEventTicksForTesting()
        let syncsBefore = await keeper.syncRequestTicksForTesting()
        await keeper.runSyncLoopIterationForTesting()
        #expect(keeper.lateStepOutputs.count == 0)
        let eventsInCall = await keeper.emittedEventTicksForTesting()
        let syncsInCall = await keeper.syncRequestTicksForTesting()
        #expect(eventsInCall.count == eventsBefore.count + 1, "the in-call emit landed")
        #expect(syncsInCall.count == Set(syncsBefore + syncsInCall).count && !syncsInCall.isEmpty, "the in-call sync request landed")

        let ctx = try #require(kept.last)
        ctx.emitEvent(StepScopeNotice(n: -1), to: .all)
        ctx.requestSyncNow()
        #expect(keeper.lateStepOutputs.count == 2, "the sync handler's scope closed when it returned")
        #expect(await keeper.emittedEventTicksForTesting() == eventsInCall)
        #expect(await keeper.syncRequestTicksForTesting() == syncsInCall)
    }

    @Test("AfterFinalize's context passes an emit after an internal await, and drops one after the keeper's close")
    func afterFinalizeContextIsScoped() async throws {
        let kept = KeptContexts()
        let transport = SentEvents()
        let definition = Land("step-scope-finalize", using: StepScopeState.self) {
            ServerEvents { Register(StepScopeNotice.self) }
            Lifetime {
                AfterFinalize { _, ctx in
                    kept.keep(ctx)
                    await Task.yield()
                    ctx.emitEvent(StepScopeNotice(n: 1), to: .all)
                }
            }
        }
        let keeper = LandKeeper<StepScopeState>(definition: definition, initialState: StepScopeState(), autoStartLoops: false, landID: "step-scope:finalize", transport: transport)
        await keeper.awaitInitialization()
        await keeper.setLateStepOutputAssertsForTesting(false)
        let eventsBefore = await keeper.emittedEventTicksForTesting()
        await keeper.forceShutdown()
        #expect(keeper.lateStepOutputs.count == 0, "the emit after the handler's await came before the keeper's close")
        let eventsAfter = await keeper.emittedEventTicksForTesting()
        #expect(eventsAfter.count + transport.values.count == eventsBefore.count + 1, "the emit landed: queued or sent")

        let ctx = try #require(kept.last)
        ctx.emitEvent(StepScopeNotice(n: -1), to: .all)
        #expect(keeper.lateStepOutputs.count == 1, "AfterFinalize's scope closed when the keeper's defer ran")
        #expect(await keeper.emittedEventTicksForTesting() == eventsAfter)
        #expect(!transport.values.contains(-1))
    }
}
