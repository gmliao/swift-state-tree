// Tests/SwiftStateTreeTests/ReentrancyHelpersTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Reentrancy helpers")
struct ReentrancyHelpersTests {
    // MARK: - GenerationTable

    @Test("A ticket is current until its key is issued again or ended")
    func ticketCurrentUntilReplaced() {
        var table = GenerationTable<String>()
        let first = table.issue("s1")
        #expect(table.isCurrent(first))
        let second = table.issue("s1")
        #expect(!table.isCurrent(first))
        #expect(table.isCurrent(second))
        table.end("s1")
        #expect(!table.isCurrent(second))
        #expect(table.ticket(for: "s1") == nil)
    }

    @Test("A ticket from an ended generation is not current after the key is issued anew")
    func endedTicketStaysStale() {
        var table = GenerationTable<String>()
        let old = table.issue("s1")
        table.end("s1")
        let new = table.issue("s1")
        #expect(!table.isCurrent(old))
        #expect(table.isCurrent(new))
        #expect(old != new)
    }

    @Test("Ending by a stale ticket leaves the newer generation alone")
    func endByStaleTicketIsNoOp() {
        var table = GenerationTable<String>()
        let old = table.issue("s1")
        let new = table.issue("s1")
        #expect(table.end(old) == false)
        #expect(table.isCurrent(new))
        #expect(table.end(new) == true)
        #expect(table.ticket(for: "s1") == nil)
    }

    @Test("ifCurrent runs the act only for a current ticket")
    func ifCurrentGuardsTheAct() {
        var table = GenerationTable<String>()
        let old = table.issue("s1")
        let new = table.issue("s1")
        var acted: [String] = []
        let skipped = table.ifCurrent(old) { proof in acted.append(proof.ticket.description) }
        let ran = table.ifCurrent(new) { proof -> Int in
            acted.append(proof.ticket.description)
            return 7
        }
        #expect(skipped == nil)
        #expect(ran == 7)
        #expect(acted == [new.description])
    }

    @Test("endAll ends every generation, and no earlier ticket becomes current again")
    func endAllKeepsCounting() {
        var table = GenerationTable<String>()
        let a = table.issue("a")
        let b = table.issue("b")
        table.endAll()
        #expect(!table.isCurrent(a))
        #expect(!table.isCurrent(b))
        let a2 = table.issue("a")
        #expect(a2 != a)
        #expect(!table.isCurrent(a))
        #expect(table.isCurrent(a2))
    }

    @Test("Keys have independent generations")
    func keysAreIndependent() {
        var table = GenerationTable<String>()
        let a = table.issue("a")
        let b = table.issue("b")
        table.issue("a")
        #expect(!table.isCurrent(a))
        #expect(table.isCurrent(b))
    }

    @Test("renew moves a current ticket on; a held ticket resolves to the renewal, not past an end or an issue")
    func renewAndResolve() throws {
        var table = GenerationTable<String>()
        let t0 = table.issue("a")
        let t1Renewal = table.renew(t0)
        let t1 = try #require(t1Renewal)
        #expect(!table.isCurrent(t0) && table.isCurrent(t1))
        let t2Renewal = table.renew(t1)
        let t2 = try #require(t2Renewal)
        // A ticket held from before the renewals resolves through both.
        #expect(table.resolve(t0) == t2)
        #expect(table.resolve(t1) == t2)
        #expect(table.renew(t0) == nil, "renew takes a current ticket only")

        // `issue` starts a generation no earlier ticket resolves to.
        let fresh = table.issue("a")
        #expect(table.resolve(t0) == nil && table.resolve(t2) == nil)
        #expect(table.resolve(fresh) == fresh)

        // `end` and `endAll` end the lineage.
        let rRenewal = table.renew(fresh)
        let r = try #require(rRenewal)
        table.end("a")
        #expect(table.resolve(fresh) == nil && table.resolve(r) == nil)
        let b0 = table.issue("b")
        let b1Renewal = table.renew(b0)
        let b1 = try #require(b1Renewal)
        table.endAll()
        #expect(table.resolve(b0) == nil && table.resolve(b1) == nil)
    }

    // MARK: - Lifecycle

    /// Begins a start the way an owner's `make` does and returns the token it was handed: the
    /// test plays the task's last step by calling `finishStart` with it.
    private func beginStart(_ lifecycle: inout Lifecycle, task: Task<Void, Error> = Task {}) -> Epoch? {
        var minted: Epoch?
        guard case .run = lifecycle.beginStart({ token in minted = token; return task }) else { return nil }
        return minted
    }

    /// The same for a stop.
    private func beginStop(_ lifecycle: inout Lifecycle, task: Task<Void, Never> = Task {}) -> Epoch? {
        var minted: Epoch?
        guard case .run = lifecycle.beginStop({ _, token in minted = token; return task }) else { return nil }
        return minted
    }

    @Test("A second start while starting joins the in-flight start; make runs once, with the token the finish takes")
    func secondStartJoins() async throws {
        var lifecycle = Lifecycle()
        let gate = AsyncGateForHelpers()
        var minted: [Epoch] = []
        guard case .run(let task) = lifecycle.beginStart({ token in
            minted.append(token)
            return Task { await gate.wait() }
        }) else {
            Issue.record("first start should run"); return
        }
        guard case .join(let joined) = lifecycle.beginStart({ token in
            minted.append(token)
            return Task {}
        }) else {
            Issue.record("second start should join"); return
        }
        #expect(minted.count == 1, "make runs only for the call that starts it")
        #expect(lifecycle.phase == .starting)
        await gate.open()
        try await task.value
        try await joined.value
        let token = try #require(minted.first)
        // The task's last step.
        lifecycle.finishStart(token, succeeded: true)
        #expect(lifecycle.phase == .running)
        guard case .alreadyRunning = lifecycle.beginStart({ _ in Task {} }) else {
            Issue.record("start while running should report alreadyRunning"); return
        }
    }

    @Test("A failed start returns to idle and can start again")
    func failedStartReturnsToIdle() throws {
        var lifecycle = Lifecycle()
        let token = try #require(beginStart(&lifecycle))
        lifecycle.finishStart(token, succeeded: false)
        #expect(lifecycle.phase == .idle)
        #expect(beginStart(&lifecycle) != nil, "restart should run")
    }

    @Test("A stop during a start gets the in-flight start and the late start outcome is ignored")
    func stopDuringStart() async throws {
        var lifecycle = Lifecycle()
        var startTask: Task<Void, Error>?
        var startToken: Epoch?
        guard case .run = lifecycle.beginStart({ token in
            startToken = token
            let task = Task<Void, Error> {}
            startTask = task
            return task
        }) else {
            Issue.record("start should run"); return
        }
        var handedStart: Task<Void, Error>?
        var stopToken: Epoch?
        guard case .run(let stopTask) = lifecycle.beginStop({ inFlight, token in
            handedStart = inFlight
            stopToken = token
            return Task {}
        }) else {
            Issue.record("stop should run"); return
        }
        #expect(handedStart == startTask)
        #expect(stopToken != startToken, "the stop mints its own token")
        #expect(lifecycle.phase == .stopping)
        // The start finishing after the stop took over does not move the phase.
        lifecycle.finishStart(try #require(startToken), succeeded: true)
        #expect(lifecycle.phase == .stopping)
        guard case .join = lifecycle.beginStop({ _, _ in Task {} }) else {
            Issue.record("second stop should join"); return
        }
        guard case .stopped = lifecycle.beginStart({ _ in Task {} }) else {
            Issue.record("start while stopping should report stopped"); return
        }
        await stopTask.value
        lifecycle.finishStop(try #require(stopToken))
        #expect(lifecycle.phase == .stopped)
        guard case .nothingToStop = lifecycle.beginStop({ _, _ in Task {} }) else {
            Issue.record("stop after stopped should be a no-op"); return
        }
        guard case .stopped = lifecycle.beginStart({ _ in Task {} }) else {
            Issue.record("a stopped resource does not start again"); return
        }
    }

    @Test("Stopping a never-started resource makes it stopped")
    func stopBeforeStart() {
        var lifecycle = Lifecycle()
        guard case .nothingToStop = lifecycle.beginStop({ _, _ in Task {} }) else {
            Issue.record("stop before start should be a no-op"); return
        }
        #expect(lifecycle.phase == .stopped)
    }

    @Test("finishStop with a start's token is a no-op in .starting, .running and .idle: the phase guard is the only barrier")
    func finishStopWithAStartTokenIsANoOp() throws {
        var lifecycle = Lifecycle()
        let startToken = try #require(beginStart(&lifecycle))
        lifecycle.finishStop(startToken)
        #expect(lifecycle.phase == .starting)
        lifecycle.finishStart(startToken, succeeded: true)
        lifecycle.finishStop(startToken)
        #expect(lifecycle.phase == .running)

        var failed = Lifecycle()
        let failedToken = try #require(beginStart(&failed))
        failed.finishStart(failedToken, succeeded: false)
        failed.finishStop(failedToken)
        #expect(failed.phase == .idle)
    }

    @Test("The late finish of an earlier start leaves a retried start alone")
    func lateFinishOfAnEarlierStartLeavesTheRetry() throws {
        var lifecycle = Lifecycle()
        let first = try #require(beginStart(&lifecycle))
        lifecycle.finishStart(first, succeeded: false)
        #expect(lifecycle.phase == .idle)
        let second = try #require(beginStart(&lifecycle))
        #expect(second != first)
        // A late call of the first start, with either outcome: the retry is still starting.
        lifecycle.finishStart(first, succeeded: false)
        #expect(lifecycle.phase == .starting)
        lifecycle.finishStart(first, succeeded: true)
        #expect(lifecycle.phase == .starting)
        lifecycle.finishStart(second, succeeded: true)
        #expect(lifecycle.phase == .running)
    }

    @Test("A second finish for the same start or stop is a no-op, whatever its outcome")
    func doubleFinishIsANoOp() throws {
        var started = Lifecycle()
        let startToken = try #require(beginStart(&started))
        started.finishStart(startToken, succeeded: true)
        started.finishStart(startToken, succeeded: false)
        #expect(started.phase == .running, "a repeated finish doesn't undo the recorded result")

        var failed = Lifecycle()
        let failedToken = try #require(beginStart(&failed))
        failed.finishStart(failedToken, succeeded: false)
        failed.finishStart(failedToken, succeeded: true)
        #expect(failed.phase == .idle)

        var stopped = Lifecycle()
        let running = try #require(beginStart(&stopped))
        stopped.finishStart(running, succeeded: true)
        let stopToken = try #require(beginStop(&stopped))
        stopped.finishStop(stopToken)
        #expect(stopped.phase == .stopped)
        stopped.finishStop(stopToken)
        #expect(stopped.phase == .stopped)
        guard case .stopped = stopped.beginStart({ _ in Task {} }) else {
            Issue.record("a stopped resource does not start again"); return
        }
    }

    // MARK: - HoldPoints

    @Test("HoldPoints calls the installed hook at each point and is a no-op without one")
    func holdPointsCallHook() async {
        enum Point: Hashable, Sendable { case a, b }
        var holds = HoldPoints<Point>()
        await holds.at(.a)
        let seen = SeenPoints()
        holds.install { point in await seen.add(point == .a ? "a" : "b") }
        await holds.at(.a)
        await holds.at(.b)
        holds.install(nil)
        await holds.at(.a)
        #expect(await seen.values == ["a", "b"])
    }
}

private actor SeenPoints {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

private actor AsyncGateForHelpers {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
