// Tests/SwiftStateTreeTests/LandKeeperActionQueueTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test State and Actions

@StateNodeBuilder
struct QueueTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var counter: Int = 0
}

struct QueueIncrementResponse: ResponsePayload {
    static func getFieldMetadata() -> [FieldMetadata] {
        return []
    }
}

@Payload
struct QueueIncrementAction: ActionPayload {
    typealias Response = QueueIncrementResponse
    
    func apply(to state: inout QueueTestState, ctx: LandContext) {
        state.counter += 1
    }
}

// MARK: - Tests

private func queueTestLand(tick interval: Duration) -> LandDefinition<QueueTestState> {
    Land("queue-test", using: QueueTestState.self) {
        Rules {
            HandleAction(QueueIncrementAction.self) { (state: inout QueueTestState, action: QueueIncrementAction, ctx: LandContext) in
                action.apply(to: &state, ctx: ctx)
                return QueueIncrementResponse()
            }
        }
        Lifetime {
            Tick(every: interval) { (_: inout QueueTestState, _: LandContext) in }
        }
    }
}

private func sendIncrement(to keeper: LandKeeper<QueueTestState>, as player: PlayerID) async throws {
    let envelope = ActionEnvelope(typeIdentifier: "QueueIncrementAction", payload: AnyCodable(QueueIncrementAction()))
    _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: ClientID("c1"), sessionID: SessionID("s1"))
}

@Test("Action is queued and executed in tick")
func testActionQueuing() async throws {
    // An hourly tick, stepped by hand: no real tick can run between the action and the "still
    // queued" check, which a short real interval allowed (#184).
    let keeper = LandKeeper(definition: queueTestLand(tick: .seconds(3600)), initialState: QueueTestState(), enableLoopPhaseOffset: false)
    let alice = PlayerID("alice")
    try await keeper.join(playerID: alice, clientID: ClientID("c1"), sessionID: SessionID("s1"))

    try await sendIncrement(to: keeper, as: alice)
    #expect(await keeper.currentState().counter == 0, "Counter should be 0 immediately after handleAction (should be queued)")
    #expect(await keeper.pendingItemSequencesForTesting().count == 1)

    await keeper.stepTickOnce()
    #expect(await keeper.currentState().counter == 1, "Counter should be 1 after tick execution")
    #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
}

/// A tick-loop clock the test steps: simulated time that moves only when the test releases the
/// loop's sleep. Each sleep is reported, so the start of the next one shows that the tick before
/// it has ended.
private final class SteppedTickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = ContinuousClock.now
    private var sleeps = 0
    private var sleeping: CheckedContinuation<Void, Never>?
    private var sleepWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var tickLoopClock: TickLoopClock {
        TickLoopClock(
            now: { self.lock.withLock { self.now } },
            sleepFor: { _ in },
            sleepUntil: { deadline in await self.sleep(until: deadline) }
        )
    }

    private func sleep(until deadline: ContinuousClock.Instant) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if Task.isCancelled {
                    // Cancelled before the sleep began: `onCancel` found nothing to resume.
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleeps += 1
                sleeping = continuation
                let reached = sleepWaiters.filter { $0.count <= sleeps }
                sleepWaiters.removeAll { $0.count <= sleeps }
                lock.unlock()
                for waiter in reached { waiter.continuation.resume() }
            }
        } onCancel: {
            // The keeper stopped its loop: end the sleep without moving time.
            self.lock.withLock { self.sleeping.take() }?.resume()
        }
        lock.withLock { if now < deadline { now = deadline } }
    }

    /// Returns once the loop has started its `count`-th sleep (at once if it has).
    func waitForSleeps(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sleeps >= count {
                lock.unlock()
                continuation.resume()
            } else {
                sleepWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// Ends the loop's current sleep: simulated time moves to its deadline and the tick runs.
    func releaseSleep() {
        lock.withLock { sleeping.take() }?.resume()
    }
}

@Test("Real tick loop: a queued action is applied by the running loop's next tick")
func testActionQueuingRealTick() async throws {
    // The loop task runs for real; only its clock is stepped. A 50 ms loop and a 2 s wait for the
    // counter missed the deadline beside CPU-heavy tests, while the order held (#447).
    let clock = SteppedTickClock()
    let keeper = TickLoopClock.$forNewKeepers.withValue(clock.tickLoopClock) {
        LandKeeper(definition: queueTestLand(tick: .milliseconds(50)), initialState: QueueTestState(), enableLoopPhaseOffset: false)
    }
    let alice = PlayerID("alice")
    try await keeper.join(playerID: alice, clientID: ClientID("c1"), sessionID: SessionID("s1"))

    try await sendIncrement(to: keeper, as: alice)
    try #require(try await withinDeadline("the loop's first sleep", deadline: .seconds(60)) { await clock.waitForSleeps(1) } != nil)
    #expect(await keeper.currentState().counter == 0, "queued until the loop ticks")

    clock.releaseSleep()
    // The loop's next sleep starts after the tick it ran has ended.
    try #require(try await withinDeadline("the loop's second sleep", deadline: .seconds(60)) { await clock.waitForSleeps(2) } != nil)
    #expect(await keeper.currentState().counter == 1, "applied by the loop's tick")
    #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
}
