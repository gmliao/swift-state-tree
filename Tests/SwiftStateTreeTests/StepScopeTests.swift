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

/// The context each tick handler call was given, kept past the call.
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
        let keeper = LandKeeper<StepScopeState>(definition: definition, initialState: StepScopeState(), autoStartLoops: false, landID: "step-scope:kept")
        await keeper.awaitInitialization()
        await keeper.setLateStepOutputAssertsForTesting(false)
        await keeper.stepTickOnce()
        #expect(keeper.lateStepOutputs.count == 0, "the emit inside the call passed")

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
}
