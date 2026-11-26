// Tests/SwiftStateTreeTests/SafeTaskSleepUntilTests.swift
//
// `safeTaskSleep(until:)`, the deadline sleep the keeper's sync loop and the continuous tick-loop
// clock use instead of `Task.sleep(until:clock:)` (#923). The checks are lower bounds and events:
// none asserts how long a sleep took.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

@Suite("safeTaskSleep(until:)")
struct SafeTaskSleepUntilTests {
    @Test("A deadline already past returns without sleeping")
    func pastDeadlineReturnsAtOnce() async throws {
        let deadline = ContinuousClock.now - .seconds(3600)
        // Sleeping the distance to this deadline would take an hour, so the test finishing shows
        // the call returned at once.
        try await safeTaskSleep(until: deadline)
        try await safeTaskSleep(until: ContinuousClock.now)
    }

    @Test("The sleep doesn't return before its deadline")
    func doesNotReturnBeforeTheDeadline() async throws {
        let deadline = ContinuousClock.now + .milliseconds(50)
        try await safeTaskSleep(until: deadline)
        #expect(ContinuousClock.now >= deadline)
    }

    @Test("Cancelling the task ends the sleep with CancellationError")
    func cancellationEndsTheSleep() async throws {
        let started = TestGate()
        // Open from the start: the sleeper's arrival only reports that it is about to sleep.
        started.open()
        let sleeper = Task { () -> Error? in
            await started.arrive()
            do {
                try await safeTaskSleep(until: ContinuousClock.now + .seconds(3600))
                return nil
            } catch {
                return error
            }
        }
        let arrived = await started.waitForArrivals(1)
        #expect(arrived, "the sleeper never started")
        sleeper.cancel()
        let error = await sleeper.value
        #expect(error is CancellationError)
    }
}
