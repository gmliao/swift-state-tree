// Notes/plans/2026-11-26-afterfinalize-outputs-probe.swift
//
// Probe for #893, run on main (copy into Tests/SwiftStateTreeTests/, with the one test accessor
// below added to LandKeeper; neither is committed):
//
//     /// Probe only: the sequence numbers of the events still in the collector, in append order.
//     func emittedEventSequencesForTesting() -> [Int64] { outputCollector.emittedEvents.map(\.sequence) }
//
// The question: does an emit that AfterFinalize makes after an await run off the keeper's actor,
// while the actor is inside another synchronous segment that also writes the output collector?
// No timing: the actor is held inside CanJoin's handler (a semaphore wait that AfterFinalize's
// emit releases), and the AfterFinalize await is a `TestGate`. If the emit needed the actor, the
// wait would time out (the timeout only turns a hang into a failed expectation).

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

@StateNodeBuilder
struct Probe893State: StateNodeProtocol {
    @Sync(.broadcast) var n: Int = 0
    public init() {}
}

@Payload
struct Probe893Event: ServerEventPayload {
    let tag: String
}

@PlainData
struct Probe893Output: ResolverOutput {
    let value: Int
}

private final class Probe893Box: @unchecked Sendable {
    static let shared = Probe893Box()
    let canJoinResolverGate = TestGate()
    let afterFinalizeGate = TestGate()
    /// Released by AfterFinalize right after its emit.
    let emitted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inHandler = false
    private var waitResult: DispatchTimeoutResult?
    var isInHandler: Bool { get { lock.withLock { inHandler } } set { lock.withLock { inHandler = newValue } } }
    var handlerWait: DispatchTimeoutResult? { get { lock.withLock { waitResult } } set { lock.withLock { waitResult = newValue } } }
}

struct Probe893CanJoinResolver: ContextResolver {
    typealias Output = Probe893Output
    static func resolve(ctx: ResolverContext) async throws -> Probe893Output {
        await Probe893Box.shared.canJoinResolverGate.arrive()
        return Probe893Output(value: 0)
    }
}

private func probe893Land() -> LandDefinition<Probe893State> {
    Land("probe-893", using: Probe893State.self) {
        ServerEvents { Register(Probe893Event.self) }
        Rules {
            CanJoin(resolvers: Probe893CanJoinResolver.self) { _, session, _, ctx in
                let box = Probe893Box.shared
                ctx.emitEvent(Probe893Event(tag: "canJoin-before"), to: .all)
                box.isInHandler = true
                // The keeper's actor is held here, inside one synchronous segment.
                box.handlerWait = box.emitted.wait(timeout: .now() + 10)
                ctx.emitEvent(Probe893Event(tag: "canJoin-after"), to: .all)
                return .allow(playerID: PlayerID(session.playerID))
            }
        }
        Lifetime {
            AfterFinalize { _, ctx in
                let box = Probe893Box.shared
                await box.afterFinalizeGate.arrive()
                ctx.emitEvent(Probe893Event(tag: "afterFinalize"), to: .all)
                box.emitted.signal()
            }
        }
    }
}

@Suite("Probe #893: AfterFinalize's emit after an await runs off the keeper's actor", .serialized, .resolverDeadlinesOff)
struct Probe893Tests {
    @Test("an AfterFinalize emit lands inside CanJoin's synchronous segment")
    func afterFinalizeEmitsInsideAnotherSegment() async throws {
        let box = Probe893Box.shared
        let keeper = LandKeeper<Probe893State>(
            definition: probe893Land(),
            initialState: Probe893State(),
            autoStartLoops: false,
            landID: "probe-893:\(UUID().uuidString)"
        )
        await keeper.awaitInitialization()

        // 1. A join parks in CanJoin's resolver.
        let join = Task {
            try? await keeper.join(
                session: PlayerSession(playerID: "p1"),
                clientID: ClientID("c1"), sessionID: SessionID("s1"), services: LandServices()
            )
        }
        #expect(await box.canJoinResolverGate.waitForArrivals(1), "the join is in CanJoin's resolver")

        // 2. The land shuts down; AfterFinalize parks at its await.
        let shutdown = Task { await keeper.forceShutdown() }
        #expect(await box.afterFinalizeGate.waitForArrivals(1), "AfterFinalize is at its await")

        // 3. The join resumes on the actor and blocks inside CanJoin's handler.
        box.canJoinResolverGate.open()
        #expect(await pollUntil { box.isInHandler }, "the actor is inside CanJoin's handler")

        // 4. AfterFinalize resumes and emits while the actor is still blocked.
        box.afterFinalizeGate.open()
        _ = await join.value
        await shutdown.value

        print("probe-893 handlerWait=\(String(describing: box.handlerWait))")
        let sequences = await keeper.emittedEventSequencesForTesting()
        print("probe-893 sequences(append order)=\(sequences)")
        // The emit ran while the actor was held: off the actor, inside another segment.
        #expect(box.handlerWait == .success)
        // canJoin-before, afterFinalize, canJoin-after: the middle one numbered inside CanJoin's segment.
        #expect(sequences.count == 3)
        #expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count)
        // No step after the drain took them: AfterFinalize's event is still in the collector.
        #expect(await keeper.emittedEventTicksForTesting().count == 3)
    }
}
