// Tests/SwiftStateTreeTests/HeldFailureTableTests.swift
//
// The failure table holds only what a caller hasn't read, and the action tables line up through
// a job's life (#700 K1b-2). Lands with the change: it reads the table's test hooks. Reuses
// HeldFailureTests' land and payloads (same module).

import Foundation
import Testing
@testable import SwiftStateTree

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// A keeper with the alignment check on at its call sites (off in production).
private func keeper(tick: Bool) async -> LandKeeper<HeldFailureState> {
    let keeper = LandKeeper<HeldFailureState>(
        definition: heldFailureDefinitionForTables(tick: tick),
        initialState: HeldFailureState(),
        autoStartLoops: false,
        landID: "held-failure-tables:local"
    )
    await keeper.setActionTableAuditForTesting(true)
    return keeper
}

private func pending(_ keeper: LandKeeper<HeldFailureState>, _ action: some ActionPayload) async throws -> Int64 {
    let submission = try await keeper.submitAction(
        ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action)),
        playerID: p1, clientID: c1, sessionID: s1
    )
    guard case .pending(let sequence) = submission else {
        Issue.record("Expected a pending job, got \(submission)")
        return -1
    }
    return sequence
}

/// The table is clean: no misses, no violations, and the check finds nothing now.
private func expectAligned(_ keeper: LandKeeper<HeldFailureState>, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    #expect(await keeper.actionTableViolationsForTesting() == [], "\(step)", sourceLocation: sourceLocation)
    #expect(await keeper.alignmentViolationsForTesting() == 0, "\(step)", sourceLocation: sourceLocation)
    #expect(await keeper.failureTableMissesForTesting() == 0, "\(step)", sourceLocation: sourceLocation)
}

@Suite("The failure table and the action tables", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct HeldFailureTableTests {
    @Test("A core's input-turn wait on the keeper's own side is a violation, counted at a check site (#700 K2-1)")
    func coreInputWaitOnTheKeepersSideIsAViolation() async throws {
        let keeper = await keeper(tick: false)
        await expectAligned(keeper, "before")
        await keeper.putCoreInputWaitForTesting(sequence: 41)
        let violations = await keeper.actionTableViolationsForTesting()
        #expect(violations.count == 1 && violations.first?.contains("core input waits [41]") == true, "\(violations)")
        // A site that checks the tables counts it: a client event's input turn resumes its waiters.
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try? await keeper.handleClientEvent(AnyClientEvent(HeldFailureEvent(token: 3)), playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.alignmentViolationsForTesting() > 0)
    }

    @Test("The table holds an unread failure until it is read, and nothing after", arguments: [true, false])
    func failureTableHoldsOnlyWhatIsUnread(tick: Bool) async throws {
        let keeper = await keeper(tick: tick)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.failureTableCountForTesting() == 0)

        let key = HeldFailureGates.freshKey()
        defer { HeldFailureGates.gate(key).release() }
        let sequence = try await pending(keeper, HeldFailureResolverAction(key: key))
        let filled = await keeper.watchActionSlotForTesting(sequence, waiter: false)
        HeldFailureGates.gate(key).release()
        guard await withinCancellingDeadline("the slot is filled", { await yields(filled) }) == true else { return }
        let unread = await keeper.failureTableCountForTesting()
        let violations = await keeper.actionTableViolationsForTesting()
        #expect(unread == 1, "one entry, under the unread slot: \(violations)")
        _ = try? await keeper.awaitActionResult(sequence: sequence)
        #expect(await keeper.failureTableCountForTesting() == 0, "read: gone")

        if !tick {
            // A tickless job whose validate throws, with no waiter yet: one entry under the slot (S2).
            let k2 = HeldFailureGates.freshKey()
            defer { HeldFailureGates.gate(k2).release() }
            let s2 = try await pending(keeper, HeldFailureResolvedValidateAction(key: k2))
            let filled2 = await keeper.watchActionSlotForTesting(s2, waiter: false)
            HeldFailureGates.gate(k2).release()
            guard await withinCancellingDeadline("the slot is filled", { await yields(filled2) }) == true else { return }
            #expect(await keeper.failureTableCountForTesting() == 1)
            _ = try? await keeper.awaitActionResult(sequence: s2)
            #expect(await keeper.failureTableCountForTesting() == 0)

            // A failed client-event turn: read by its caller in the drain, nothing left.
            _ = try? await keeper.handleClientEvent(AnyClientEvent(HeldFailureEvent(token: 3)), playerID: p1, clientID: c1, sessionID: s1)
            #expect(await keeper.failureTableCountForTesting() == 0)
        }
        await expectAligned(keeper, "end")
    }

    @Test("The action tables line up after each step of a job's life")
    func actionTablesStayAlignedThroughAJobsLife() async throws {
        let keeper = await keeper(tick: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        let resolved = HeldFailureGates.freshKey()
        let a = try await pending(keeper, HeldFailureResolverAction(key: resolved))
        await expectAligned(keeper, "admitted")
        HeldFailureGates.gate(resolved).release()
        _ = try? await keeper.awaitActionResult(sequence: a)
        await expectAligned(keeper, "resolved and read")

        // Abandoned: the caller is cancelled while the resolver holds. Only a job started under a
        // deadline races its resolvers, so a cancelled caller returns at once; with the suite's
        // deadlines off it would wait for the gate.
        let abandoned = HeldFailureGates.freshKey()
        defer { HeldFailureGates.gate(abandoned).release() }
        let b = try await ResolverDeadline.$overrideForTesting.withValue(.seconds(30)) {
            try await pending(keeper, HeldFailureResolverAction(key: abandoned))
        }
        guard await HeldFailureGates.gate(abandoned).waitUntilEntered("the resolver starts") else { return }
        let waits = await keeper.watchActionSlotForTesting(b, waiter: true)
        let waiter = Task { () -> (any Error)? in
            do { _ = try await keeper.awaitActionResult(sequence: b); return nil } catch { return error }
        }
        guard await withinCancellingDeadline("the caller waits", { await yields(waits) }) == true else {
            waiter.cancel()
            return
        }
        waiter.cancel()
        guard let cancelled = await withinCancellingDeadline("the cancelled caller returns", { await waiter.value }) else { return }
        #expect(cancelled is CancellationError, "the caller gets CancellationError: \(String(describing: cancelled))")
        await expectAligned(keeper, "abandoned")
        // The abandoned job keeps its place in the caps until its resolver ends.
        #expect(await keeper.actionJobCountsForTesting().jobs == 1, "the abandoned job still counts")
        HeldFailureGates.gate(abandoned).release()
        _ = try await withinDeadline("the abandoned job settles") { await keeper.waitForActionJobsForTesting() }
        #expect(await keeper.actionJobCountsForTesting().jobs == 0, "the released job left the job table")
        await expectAligned(keeper, "abandoned, released")

        // Cancelled by a leave, then by the drain.
        let byLeave = HeldFailureGates.freshKey()
        let c = try await pending(keeper, HeldFailureResolverAction(key: byLeave))
        guard await HeldFailureGates.gate(byLeave).waitUntilEntered() else { return }
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        await expectAligned(keeper, "cancelled by a leave")
        _ = try? await keeper.awaitActionResult(sequence: c)
        HeldFailureGates.gate(byLeave).release()

        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let byDrain = HeldFailureGates.freshKey()
        let d = try await pending(keeper, HeldFailureResolverAction(key: byDrain))
        guard await HeldFailureGates.gate(byDrain).waitUntilEntered() else { return }
        await keeper.forceShutdown()
        await expectAligned(keeper, "cancelled by the drain")
        _ = try? await keeper.awaitActionResult(sequence: d)
        HeldFailureGates.gate(byDrain).release()
        _ = try await withinDeadline("the jobs settle") { await keeper.waitForActionJobsForTesting() }
        await expectAligned(keeper, "settled")
        #expect(await keeper.failureTableCountForTesting() == 0)
    }

    @Test("The input-turn result setter consumes the failure it displaces")
    func inputTurnResultSetterConsumesWhatItDisplaces() async throws {
        let keeper = await keeper(tick: true)
        await keeper.setInputTurnResultForTesting(900, .failure(HeldFailureError(token: 1)))
        #expect(await keeper.failureTableCountForTesting() == 1)
        await keeper.setInputTurnResultForTesting(900, .failure(HeldFailureError(token: 2)))
        #expect(await keeper.failureTableCountForTesting() == 1, "a failure replaced by a failure")
        await keeper.setInputTurnResultForTesting(900, nil)
        #expect(await keeper.failureTableCountForTesting() == 0, "a failure replaced by nil")
        await expectAligned(keeper, "after the setter")
    }
}
