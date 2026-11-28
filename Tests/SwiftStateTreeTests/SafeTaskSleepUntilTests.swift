// Tests/SwiftStateTreeTests/SafeTaskSleepUntilTests.swift
//
// `safeTaskSleep(until:)`, the deadline sleep the keeper's sync loop and the continuous tick-loop
// clock use instead of `Task.sleep(until:clock:)` (#923). The checks are lower bounds and events:
// none asserts how long a sleep took. Every wait on a task that a bug could leave running is
// bounded (`withinCancellingDeadline`), so a broken sleep fails a test within `TestBounds.hang`
// instead of hanging it: awaiting an unstructured task's `value` ignores the waiter's
// cancellation, so a suite time limit alone would not end such a wait.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree

/// What a sleeping call ended with, set once.
private final class SleepOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Result<Void, Error>?
    private var durations: [Duration] = []

    func record(_ result: Result<Void, Error>) { lock.withLock { recorded = result } }
    var result: Result<Void, Error>? { lock.withLock { recorded } }

    func recordRequest(_ duration: Duration) { lock.withLock { durations.append(duration) } }
    var requests: [Duration] { lock.withLock { durations } }
}

/// A clock a test moves by hand.
private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant

    init(_ start: ContinuousClock.Instant) { instant = start }

    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant + duration } }
}

@Suite("safeTaskSleep(until:)", .timeLimit(.minutes(1)))
struct SafeTaskSleepUntilTests {
    @Test("A deadline already past returns without sleeping")
    func pastDeadlineReturnsAtOnce() async {
        // Sleeping the distance to this deadline would take an hour: the bound fails a call that
        // does, instead of letting the test wait it out.
        let past = ContinuousClock.now - .seconds(3600)
        let returned = await withinCancellingDeadline("a past deadline returned") { () -> Bool in
            do {
                try await safeTaskSleep(until: past)
                try await safeTaskSleep(until: ContinuousClock.now)
                return true
            } catch {
                return false
            }
        }
        #expect(returned == true)
    }

    @Test("The sleep doesn't return before its deadline")
    func doesNotReturnBeforeTheDeadline() async {
        let deadline = ContinuousClock.now + .milliseconds(50)
        let returned = await withinCancellingDeadline("the sleep returned") { () -> Bool in
            do {
                try await safeTaskSleep(until: deadline)
                return true
            } catch {
                return false
            }
        }
        #expect(returned == true)
        #expect(ContinuousClock.now >= deadline)
    }

    /// Runs `safeTaskSleep(until: deadline)` in a task that signals once the sleep is armed (the
    /// sleeper has been asked for its first duration and is about to sleep it), cancels it, and
    /// waits for it to end within a bound. Returns what it ended with, and the durations it asked
    /// for; nil, with an issue recorded, when it never armed or never ended.
    private func cancelledSleep(
        until deadline: ContinuousClock.Instant,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> SleepOutcome? {
        let armed = TestGate()
        let finished = TestGate()
        // Open from the start: an arrival only reports that it happened.
        armed.open()
        finished.open()
        let outcome = SleepOutcome()
        let sleeper = Task {
            do {
                try await safeTaskSleep(
                    until: deadline,
                    now: { ContinuousClock.now },
                    sleepFor: { duration in
                        outcome.recordRequest(duration)
                        await armed.arrive()
                        // A request above the cap is the no-cap bug: the real sleeper would return
                        // at once on overflow and the loop would spin, so fail here and end it.
                        guard duration <= .seconds(3600) else {
                            Issue.record("the sleep asked for \(duration), above the one-hour cap", sourceLocation: sourceLocation)
                            throw UncappedRequest()
                        }
                        try await safeTaskSleep(for: duration)
                    }
                )
                outcome.record(.success(()))
            } catch {
                outcome.record(.failure(error))
            }
            await finished.arrive()
        }
        let didArm = await withinCancellingDeadline("the sleep armed", sourceLocation: sourceLocation) {
            await armed.waitForArrivals(1)
        }
        guard didArm == true else {
            sleeper.cancel()
            return nil
        }
        sleeper.cancel()
        let ended = await withinCancellingDeadline("the cancelled sleep ended", sourceLocation: sourceLocation) {
            await finished.waitForArrivals(1)
        }
        // A sleep that never ended is left behind: awaiting it would hang the test.
        return ended == true ? outcome : nil
    }

    @Test("Cancelling the task ends the sleep with CancellationError")
    func cancellationEndsTheSleep() async {
        let deadline = ContinuousClock.now + .seconds(3600)
        guard let outcome = await cancelledSleep(until: deadline) else { return }
        guard case .failure(let error)? = outcome.result else {
            Issue.record("the cancelled sleep returned instead of throwing: \(String(describing: outcome.result))")
            return
        }
        #expect(error is CancellationError)
    }

    @Test("A far deadline sleeps in capped chunks, and cancelling it ends it with CancellationError")
    func farDeadlineIsCappedAndCancellable() async {
        // 2^40 seconds is about 35,000 years: its nanoseconds overflow UInt64, so a sleep of the
        // whole remainder would be clamped to the longest sleep (until cancelled), and the loop
        // would never read the clock again. The one-hour cap keeps each sleep short.
        let deadline = ContinuousClock.now + .seconds(1 << 40)
        guard let outcome = await cancelledSleep(until: deadline) else { return }
        guard case .failure(let error)? = outcome.result else {
            Issue.record("the cancelled sleep returned instead of throwing: \(String(describing: outcome.result))")
            return
        }
        #expect(error is CancellationError)
        #expect(outcome.requests == [.seconds(3600)], "the first sleep is capped at one hour")
    }

    @Test("The clock is read again after each wake, and only what is left is slept")
    func clockIsReadAgainAfterEachWake() async throws {
        let base = ContinuousClock.now
        let clock = ScriptedClock(base)
        let requests = SleepOutcome()
        // The sleeper's progress per wake: full, early (100 s of a 3600 s request), full, full.
        let progress: [Duration] = [.seconds(3600), .seconds(100), .seconds(3600), .seconds(1700)]
        let call = SleepCounter()
        // A sleep asked for past the script (an extra request, as a `>=` guard or a clock read
        // hoisted out of the loop makes) records an issue and throws, ending the loop as a failure
        // instead of indexing past the end.
        do {
            try await safeTaskSleep(
                until: base + .seconds(9000),
                now: { clock.now },
                sleepFor: { duration in
                    requests.recordRequest(duration)
                    let index = call.next()
                    guard index < progress.count else {
                        Issue.record("unexpected request \(duration) after the script")
                        throw ScriptExhausted()
                    }
                    clock.advance(by: progress[index])
                }
            )
        } catch is ScriptExhausted {
            // Recorded above.
        }
        #expect(requests.requests == [.seconds(3600), .seconds(3600), .seconds(3600), .seconds(1700)])
        #expect(clock.now >= base + .seconds(9000))
    }
}

/// Thrown by a scripted sleeper that is asked for more than its script holds.
private struct ScriptExhausted: Error {}

/// Thrown by the cancellation tests' sleeper when asked for more than the one-hour cap.
private struct UncappedRequest: Error {}

/// A counter for the scripted sleeper.
private final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}
