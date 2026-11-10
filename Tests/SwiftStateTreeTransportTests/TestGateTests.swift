// Tests/SwiftStateTreeTransportTests/TestGateTests.swift
//
// The gate's own waits: a cancelled `waitForArrivals` ends at once, not at the next arrival or
// the hang bound.

import Foundation
import Testing

@Suite("TestGate", .timeLimit(.minutes(1)))
struct TestGateTests {
    @Test("A cancelled waitForArrivals returns false at once, and a later arrival doesn't resume it")
    func cancelledWaitEnds() async throws {
        let gate = TestGate()
        gate.open()
        let wait = Task { await gate.waitForArrivals(1) }
        try #require(await pollUntil { gate.arrivalWaiterCount == 1 }, "the wait registered")
        // The wait is inside its cancellation handler, so cancel() ends it before the arrival.
        wait.cancel()
        await gate.arrive()
        #expect(await wait.value == false)
        #expect(gate.arrivalWaiterCount == 0)
    }

    @Test("A wait whose task was cancelled before it began returns false without registering")
    func cancelledBeforeTheWait() async throws {
        let gate = TestGate()
        let finished = FinishedFlag()
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            defer { finished.set() }
            return await gate.waitForArrivals(1)
        }
        // Ends on either outcome: the wait returning, or a registered waiter (the bug).
        try #require(await pollUntil { finished.isSet || gate.arrivalWaiterCount > 0 })
        #expect(gate.arrivalWaiterCount == 0, "a cancelled task's wait registered")
        gate.open()
        await gate.arrive()
        #expect(await wait.value == false)
    }

    @Test("A wait whose count was already reached returns true, cancelled or not")
    func reachedCountWins() async {
        let gate = TestGate()
        gate.open()
        await gate.arrive()
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.waitForArrivals(1)
        }
        #expect(await wait.value == true)
    }
}

private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
