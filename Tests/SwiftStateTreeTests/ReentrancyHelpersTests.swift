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

    @Test("A second start while starting joins the in-flight start")
    func secondStartJoins() async throws {
        var lifecycle = Lifecycle()
        let gate = AsyncGateForHelpers()
        guard case .run(let task, let token) = lifecycle.beginStart({ Task { await gate.wait() } }) else {
            Issue.record("first start should run"); return
        }
        guard case .join(let joined) = lifecycle.beginStart({ Task {} }) else {
            Issue.record("second start should join"); return
        }
        #expect(lifecycle.phase == .starting)
        await gate.open()
        try await task.value
        try await joined.value
        lifecycle.finishStart(token, succeeded: true)
        #expect(lifecycle.phase == .running)
        guard case .alreadyRunning = lifecycle.beginStart({ Task {} }) else {
            Issue.record("start while running should report alreadyRunning"); return
        }
    }

    @Test("A failed start returns to idle and can start again")
    func failedStartReturnsToIdle() {
        var lifecycle = Lifecycle()
        guard case .run(_, let token) = lifecycle.beginStart({ Task {} }) else {
            Issue.record("start should run"); return
        }
        lifecycle.finishStart(token, succeeded: false)
        #expect(lifecycle.phase == .idle)
        guard case .run = lifecycle.beginStart({ Task {} }) else {
            Issue.record("restart should run"); return
        }
    }

    @Test("A stop during a start gets the in-flight start and the late start outcome is ignored")
    func stopDuringStart() async {
        var lifecycle = Lifecycle()
        guard case .run(let startTask, let startToken) = lifecycle.beginStart({ Task {} }) else {
            Issue.record("start should run"); return
        }
        var handedStart: Task<Void, Error>?
        guard case .run(let stopTask, let stopToken) = lifecycle.beginStop({ inFlight in
            handedStart = inFlight
            return Task {}
        }) else {
            Issue.record("stop should run"); return
        }
        #expect(handedStart == startTask)
        #expect(lifecycle.phase == .stopping)
        // The start finishing after the stop took over does not move the phase.
        lifecycle.finishStart(startToken, succeeded: true)
        #expect(lifecycle.phase == .stopping)
        guard case .join = lifecycle.beginStop({ _ in Task {} }) else {
            Issue.record("second stop should join"); return
        }
        guard case .stopped = lifecycle.beginStart({ Task {} }) else {
            Issue.record("start while stopping should report stopped"); return
        }
        await stopTask.value
        lifecycle.finishStop(stopToken)
        #expect(lifecycle.phase == .stopped)
        guard case .nothingToStop = lifecycle.beginStop({ _ in Task {} }) else {
            Issue.record("stop after stopped should be a no-op"); return
        }
        guard case .stopped = lifecycle.beginStart({ Task {} }) else {
            Issue.record("a stopped resource does not start again"); return
        }
    }

    @Test("Stopping a never-started resource makes it stopped")
    func stopBeforeStart() {
        var lifecycle = Lifecycle()
        guard case .nothingToStop = lifecycle.beginStop({ _ in Task {} }) else {
            Issue.record("stop before start should be a no-op"); return
        }
        #expect(lifecycle.phase == .stopped)
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
