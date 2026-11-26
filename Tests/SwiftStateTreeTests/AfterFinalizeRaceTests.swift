// Tests/SwiftStateTreeTests/AfterFinalizeRaceTests.swift
//
// #893: AfterFinalize is async, and an emit it makes after an internal await runs off the keeper's
// actor. Before the fix that emit wrote the output collector while the actor was inside another
// synchronous segment that also wrote it (the probe in
// Notes/plans/2026-11-26-afterfinalize-outputs-probe.swift). Now a destroy handler's outputs are
// dropped, so nothing reaches the collector off the actor. The actor is held inside CanJoin's
// handler (a semaphore that only AfterFinalize's emit releases), never by timing: the timeout
// only turns a hang into a failed expectation.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

@StateNodeBuilder
struct AfterFinalizeRaceState: StateNodeProtocol {
    @Sync(.broadcast) var n: Int = 0
    public init() {}
}

@Payload
struct AfterFinalizeRaceEvent: ServerEventPayload {
    let tag: String
}

@PlainData
struct AfterFinalizeRaceOutput: ResolverOutput {
    let value: Int
}

/// One land's gates and flags, keyed by its land ID, so repeated runs don't share them.
private final class AfterFinalizeRaceBox: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var boxes: [String: AfterFinalizeRaceBox] = [:]

    static func box(for landID: String) -> AfterFinalizeRaceBox {
        registryLock.withLock {
            if let box = boxes[landID] { return box }
            let box = AfterFinalizeRaceBox()
            boxes[landID] = box
            return box
        }
    }

    let canJoinResolverGate = TestGate()
    let afterFinalizeGate = TestGate()
    /// Released by AfterFinalize right after its emit.
    let emitted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inHandler = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var waitResult: DispatchTimeoutResult?

    /// Called by CanJoin's handler on the actor: wakes the test waiting in `handlerEntered()`.
    func enterHandler() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            inHandler = true
            defer { enteredWaiter = nil }
            return enteredWaiter
        }
        waiter?.resume()
    }

    /// Whether CanJoin's handler has entered.
    var isInHandler: Bool { lock.withLock { inHandler } }

    /// Returns once CanJoin's handler has entered (an event, not a poll), or when the waiting
    /// task is cancelled (`withinHangBound`).
    func handlerEntered() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let entered = lock.withLock { () -> Bool in
                    if inHandler || Task.isCancelled { return true }
                    enteredWaiter = continuation
                    return false
                }
                if entered { continuation.resume() }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { enteredWaiter = nil }
                return enteredWaiter
            }
            waiter?.resume()
        }
    }

    var handlerWait: DispatchTimeoutResult? { get { lock.withLock { waitResult } } set { lock.withLock { waitResult = newValue } } }
}

struct AfterFinalizeRaceCanJoinResolver: ContextResolver {
    typealias Output = AfterFinalizeRaceOutput
    static func resolve(ctx: ResolverContext) async throws -> AfterFinalizeRaceOutput {
        await AfterFinalizeRaceBox.box(for: ctx.landID).canJoinResolverGate.arrive()
        return AfterFinalizeRaceOutput(value: 0)
    }
}

private func afterFinalizeRaceLand() -> LandDefinition<AfterFinalizeRaceState> {
    Land("after-finalize-race", using: AfterFinalizeRaceState.self) {
        ServerEvents { Register(AfterFinalizeRaceEvent.self) }
        Rules {
            CanJoin(resolvers: AfterFinalizeRaceCanJoinResolver.self) { _, session, _, ctx in
                let box = AfterFinalizeRaceBox.box(for: ctx.landID)
                ctx.emitEvent(AfterFinalizeRaceEvent(tag: "canJoin-before"), to: .all)
                box.enterHandler()
                // The keeper's actor is held here, inside one synchronous segment.
                box.handlerWait = box.emitted.wait(timeout: .now() + 10)
                ctx.emitEvent(AfterFinalizeRaceEvent(tag: "canJoin-after"), to: .all)
                return .allow(playerID: PlayerID(session.playerID))
            }
        }
        Lifetime {
            AfterFinalize { _, ctx in
                let box = AfterFinalizeRaceBox.box(for: ctx.landID)
                await box.afterFinalizeGate.arrive()
                ctx.emitEvent(AfterFinalizeRaceEvent(tag: "afterFinalize"), to: .all)
                box.emitted.signal()
            }
        }
    }
}

@Suite("AfterFinalize's emit after an await doesn't reach the output collector (#893)", .serialized, .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct AfterFinalizeRaceTests {
    @Test("an AfterFinalize emit made while the actor is in CanJoin's segment is dropped, not appended")
    func afterFinalizeEmitsInsideAnotherSegment() async throws {
        let landID = "after-finalize-race:\(UUID().uuidString)"
        let box = AfterFinalizeRaceBox.box(for: landID)
        let keeper = LandKeeper<AfterFinalizeRaceState>(
            definition: afterFinalizeRaceLand(),
            initialState: AfterFinalizeRaceState(),
            autoStartLoops: false,
            landID: landID
        )
        defer { box.canJoinResolverGate.open(); box.afterFinalizeGate.open(); box.emitted.signal() }
        await keeper.awaitInitialization()

        // 1. A join parks in CanJoin's resolver.
        let join = Task {
            try? await keeper.join(
                session: PlayerSession(playerID: "p1"),
                clientID: ClientID("c1"), sessionID: SessionID("s1"), services: LandServices()
            )
        }
        try #require(await box.canJoinResolverGate.waitForArrivals(1), "the join is in CanJoin's resolver")

        // 2. The land shuts down; AfterFinalize parks at its await.
        let shutdown = Task { await keeper.forceShutdown() }
        try #require(await box.afterFinalizeGate.waitForArrivals(1), "AfterFinalize is at its await")

        // 3. The join resumes on the actor and blocks inside CanJoin's handler.
        box.canJoinResolverGate.open()
        try #require(await withinHangBound { await box.handlerEntered() } && box.isInHandler, "the actor is inside CanJoin's handler")

        // 4. AfterFinalize resumes and emits while the actor is still blocked.
        box.afterFinalizeGate.open()
        _ = await join.value
        await shutdown.value

        // AfterFinalize resumed off the keeper while the actor was held in CanJoin's segment.
        #expect(box.handlerWait == .success)
        // Its emit didn't reach the collector, and was dropped and counted. CanJoin's two events
        // are dropped and counted too (#700 K2-E2), so the collector holds nothing.
        #expect(await keeper.emittedEventTicksForTesting().isEmpty)
        #expect(keeper.destroyHandlerOutputsDropped.count == 1)
        #expect(keeper.readOnlyHandlerOutputsDropped.count == 2)
        #expect(keeper.lateStepOutputs.count == 0)
    }
}
