//
//  SafeTaskSleep.swift
//  SwiftStateTree
//
//  Created: 2026-01-26
//
//  Created to work around a Swift Concurrency runtime bug where Task.sleep(for: Duration)
//  can crash in macOS release builds under load (SIGABRT in swift_task_dealloc).
//
//  This module provides a safe alternative that converts Duration to nanoseconds
//  and uses Task.sleep(nanoseconds:) instead.
//
//  Related:
//  - Repository: https://github.com/gmliao/swift-state-tree
//  - Investigation: See Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md
//  - Swift Concurrency Runtime Bug: Task.sleep(for: Duration) crashes on macOS release builds
//

import Foundation

/// Safe wrapper around Task.sleep that avoids the macOS release build crash bug.
///
/// **DO NOT use `Task.sleep(for:)` directly in library code.**
/// Use this function instead for all sleep operations in `Sources/SwiftStateTree`.
///
/// This function converts `Duration` to nanoseconds and uses `Task.sleep(nanoseconds:)`
/// to work around a known Swift Concurrency runtime bug on macOS release builds.
///
/// - Parameter duration: The duration to sleep for.
/// - Throws: `CancellationError` if the task is cancelled during sleep.
public func safeTaskSleep(for duration: Duration) async throws {
    // Convert Duration to nanoseconds for Task.sleep(nanoseconds:).
    //
    // NOTE: We intentionally avoid Task.sleep(for:) here. It was observed to crash in
    // macOS release builds under load (SIGABRT in swift_task_dealloc).
    //
    // NOTE: We read `attoseconds` (Int128), not `components`. `Duration.components` converts the
    // seconds part to Int64 and traps for a duration past Int64.max seconds (#963).
    let attoseconds = duration.attoseconds

    // A negative duration needs no sleep.
    guard attoseconds >= 0 else {
        return
    }

    // 1e9 attoseconds per nanosecond. A duration past UInt64's nanoseconds (about 584 years)
    // sleeps for the longest the sleep can take, until cancelled.
    let nanos = attoseconds / 1_000_000_000
    let totalNanos = nanos > Int128(UInt64.max) ? UInt64.max : UInt64(nanos)

    // Use Task.sleep(nanoseconds:) instead of Task.sleep(for:)
    try await Task.sleep(nanoseconds: totalNanos)
}

/// The longest single sleep of `safeTaskSleep(until:)`: one hour.
///
/// This cap keeps the clock read between sleeps. `safeTaskSleep(for:)` clamps a duration whose
/// nanoseconds overflow `UInt64` (about 584 years) to the longest sleep it can take, so a far
/// deadline sleeping its whole remainder would never read the clock again. With the cap, every
/// sleep is short, and a longer wait is taken in chunks.
private let longestDeadlineSleepChunk: Duration = .seconds(3600)

/// Sleeps until `deadline` on the continuous clock, without `Task.sleep(until:clock:)`.
///
/// **DO NOT use `Task.sleep(until:clock:)` directly in library code**, for the same reason as
/// `Task.sleep(for:)`: it was not shown safe against the macOS release-build crash.
/// `scripts/lint-lessons.sh` (`task-sleep`) rejects both.
///
/// It returns at once for a deadline that has already passed. Otherwise it sleeps the time left
/// with `safeTaskSleep(for:)` (at most one hour at a time, see `longestDeadlineSleepChunk`) and
/// reads the clock again after each wake, so a timed sleep that wakes early sleeps on for what is
/// left (as `SystemTurnClock` does). It returns only once the clock has reached `deadline`,
/// unless the task is cancelled.
///
/// - Parameter deadline: The instant on `ContinuousClock` to sleep until.
/// - Throws: `CancellationError` if the task is cancelled during sleep.
package func safeTaskSleep(until deadline: ContinuousClock.Instant) async throws {
    try await safeTaskSleep(
        until: deadline,
        now: { ContinuousClock.now },
        sleepFor: { try await safeTaskSleep(for: $0) }
    )
}

/// `safeTaskSleep(until:)` with its clock and its sleeper passed in, so a test can script the
/// durations asked for and the clock's progress between wakes.
package func safeTaskSleep(
    until deadline: ContinuousClock.Instant,
    now: @Sendable () -> ContinuousClock.Instant,
    sleepFor: @Sendable (Duration) async throws -> Void
) async throws {
    while true {
        let remaining = deadline - now()
        guard remaining > .zero else { return }
        try await sleepFor(min(remaining, longestDeadlineSleepChunk))
    }
}
