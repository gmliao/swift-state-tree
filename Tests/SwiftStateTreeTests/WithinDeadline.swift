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

/// Waits until `keeper`'s abandonment count for `kind` reaches `count`, within a deadline:
/// a missing transition fails the test instead of hanging it.
func expectAbandoned<S: StateNodeProtocol>(
    _ keeper: LandKeeper<S>,
    _ kind: ResolverAbandonment.Kind,
    _ count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    _ = try await withinDeadline("\(kind) abandoned count \(count)", sourceLocation: sourceLocation) {
        await keeper.abandonmentCounter.waitForCount(kind, count)
    }
    #expect(keeper.abandonmentCounter.count(kind) == count, sourceLocation: sourceLocation)
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

    @Test("A gate entered before the wait starts returns true without registering a wait")
    func gateEnteredFirst() async {
        let gate = WatermarkGate()
        let entry = Task { await gate.enterAndWait() }
        // The first wait returns once the entry has landed, so the second starts after it.
        #expect(await gate.waitUntilEntered("the entry lands"))
        let (registrations, observer) = AsyncStream<Void>.makeStream()
        gate.observeRegistrationsForTesting(observer)
        #expect(await gate.waitUntilEntered())
        observer.finish()
        var registered = 0
        for await _ in registrations { registered += 1 }
        #expect(registered == 0, "an entered gate registers no wait")
        gate.release()
        await entry.value
    }

    @Test("A gate entered after the wait registered resumes that wait with true")
    func gateEnteredAfterRegistration() async {
        let gate = WatermarkGate()
        let (registrations, observer) = AsyncStream<Void>.makeStream()
        gate.observeRegistrationsForTesting(observer)
        let waiter = Task { await gate.waitUntilEntered() }
        // The entry starts only once the wait has registered.
        guard case .finished = await raceDeadline(.seconds(10), {
            for await _ in registrations { return }
        }) else {
            Issue.record("the wait never registered")
            gate.release()
            return
        }
        let entry = Task { await gate.enterAndWait() }
        #expect(await waiter.value)
        #expect(gate.registeredEntryWaitsForTesting == 0)
        gate.release()
        await entry.value
    }

    @Test("A gate never entered fails the wait by name at its deadline and unregisters it")
    func gateNeverEntered() async {
        let gate = WatermarkGate()
        let result = EntryResult()
        await withKnownIssue("the bound's own issue") {
            await result.set(gate.waitUntilEntered("the hold fires", deadline: .milliseconds(50)))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("WatermarkGate never entered within") && $0.rawValue.contains("the hold fires") }
        }
        #expect(await result.value == false)
        #expect(gate.registeredEntryWaitsForTesting == 0, "the timed-out wait is removed")
        // A late entry after the release passes straight through.
        gate.release()
        await gate.enterAndWait()
    }

    @Test("A caller whose entry times out returns instead of parking at the next await")
    func callerReturnsAfterFailedEntry() async {
        let gate = WatermarkGate()
        // Nothing releases `next` before the end: a caller that went on past a failed entry
        // parks there.
        let next = WatermarkGate()
        await withKnownIssue("the bound's own issue") {
            let caller = Task { () -> String in
                guard await gate.waitUntilEntered("the hold fires", deadline: .milliseconds(50)) else { return "returned" }
                await next.enterAndWait()
                return "went on"
            }
            switch await raceDeadline(.seconds(10), { await caller.value }) {
            case .finished(let outcome):
                #expect((try? outcome.get()) == "returned")
            case .timedOut:
                Issue.record("the caller parked after its failed entry")
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("WatermarkGate never entered within") }
        }
        next.release()
    }
}

/// One Bool, set once, read after.
private actor EntryResult {
    private(set) var value: Bool?
    func set(_ newValue: Bool) { value = newValue }
}
