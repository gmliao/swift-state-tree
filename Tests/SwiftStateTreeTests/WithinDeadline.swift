// Tests/SwiftStateTreeTests/WithinDeadline.swift
//
// Turns a hang at a held step into a test failure that names the step (`raceDeadline`).

import Testing
@testable import SwiftStateTree

/// Awaits `work`, but at most `deadline`. On timeout, records an issue naming `step` and
/// returns `nil`, leaving the stuck task behind; the caller returns from the test. Errors
/// thrown by `work` are rethrown.
func withinDeadline<Value: Sendable>(
    _ step: String,
    deadline: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value? {
    switch await raceDeadline(deadline, work) {
    case .finished(let result):
        return try result.get()
    case .timedOut:
        Issue.record("Timed out after \(deadline): \(step)", sourceLocation: sourceLocation)
        return nil
    }
}

@Suite("raceDeadline")
struct RaceDeadlineTests {
    @Test("Work that finishes first wins, with its value or its error")
    func workFinishesFirst() async {
        guard case .finished(let value) = await raceDeadline(.seconds(10), { 42 }) else {
            Issue.record("Expected the work to finish first")
            return
        }
        #expect((try? value.get()) == 42)

        struct Boom: Error {}
        guard case .finished(let failure) = await raceDeadline(.seconds(10), { () async throws -> Int in throw Boom() }) else {
            Issue.record("Expected the work to finish first")
            return
        }
        #expect(throws: Boom.self) { try failure.get() }
    }

    @Test("Work that never returns loses to the deadline; the race returns anyway")
    func deadlineFirst() async {
        let gate = WatermarkGate()
        let outcome = await raceDeadline(.milliseconds(50)) { await gate.enterAndWait() }
        guard case .timedOut = outcome else {
            Issue.record("Expected the deadline to pass first")
            return
        }
        gate.release()
    }
}
