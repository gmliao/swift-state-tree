// Tests/SwiftStateTreeTests/SafeTaskSleepForTests.swift
//
// `safeTaskSleep(for:)` takes a caller's duration, so it must not trap on one (#963):
// `Duration.components` traps past Int64.max seconds, and the sleep reads `attoseconds` instead.
// None of these checks waits on the wall clock.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("safeTaskSleep(for:)", .timeLimit(.minutes(1)))
struct SafeTaskSleepForTests {
    @Test("A negative duration returns at once")
    func negativeDurationReturnsAtOnce() async throws {
        try await safeTaskSleep(for: .seconds(-3600))
        try await safeTaskSleep(for: .nanoseconds(-1))
    }

    @Test("A duration past Int64.max seconds doesn't trap: cancelling the task ends the sleep")
    func durationPastInt64MaxSecondsDoesNotTrap() async {
        // The sum is fine (Duration holds 128 bits); only `components` traps on it.
        let huge = Duration.seconds(Int64.max) + .seconds(1)
        let task = Task { try await safeTaskSleep(for: huge) }
        task.cancel()
        do {
            try await task.value
            Issue.record("the sleep returned instead of throwing")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
