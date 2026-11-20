// Tests/SwiftStateTreeNIOTests/Differential/DiffLeaveTurnTests.swift
//
// #676: in disconnect-during-keeper-join on a tickless land, the queued leave runs its own input
// turn once the held join returns. A legacy sync cycle that holds the keeper's sync flag while
// that turn runs moves the turn's sync phase into a sync-only turn after the cycle's `endSync`,
// so the record's output after the leave's pass reads `syncOnly` instead of `tick`. The row pins
// the order with `awaitDisconnectForwards` (and a flush before the leave, against the writer's
// back-pressure). This test holds a cycle open over the leave's turn and checks the flake's
// mechanism: the turn leaves its sync to the sync-only turn after `endSync`, and no output after
// its pass is a tick's. It also checks the pinned row's output at the flake's index.
//
// No test forces the pin itself: its guarantee is the chain from the forward to the leave's
// turn (the router's forward count, the adapter's membership queue, the keeper's leave awaiting
// its input turn), and the pinned check here passes whenever the leave wins.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

extension DifferentialHarness {
    @Suite("Differential harness: the leave's turn and a legacy cycle (#676)", .resolverDeadlinesOff)
    struct DiffLeaveTurnTests {
        /// The cell the flake showed in.
        private let cell = DiffCell(sync: .inTurn, encoding: .messagepack, land: .tickless)
        /// B's join is pass 1, A's join pass 2, and A's leave pass 3.
        private let leavePass: Int64 = 3

        @Test("A legacy cycle held over the leave's turn defers its sync to a sync-only turn; the pinned row keeps it in the turn")
        func heldCycleMovesTheLeaveSync() async throws {
            // The in-turn cell is masked with IN_TURN_SYNC=false.
            guard InTurnSync.isEnabled() else { return }

            // The flake was `syncOutputs[3]`: sequence 3, after pass 3, `tick` then `syncOnly`.
            let pinned = try #require(diffScenarios.first { $0.name == "disconnect-during-keeper-join" })
            let pinnedOutputs = try syncOutputs(try await runChecked(pinned, cell))
            try #require(pinnedOutputs.count > 3, "the pinned row has \(pinnedOutputs.count) sync outputs")
            #expect(
                pinnedOutputs[3] == SyncOutput(kind: "tick", afterPass: leavePass, sequence: 3),
                "the pinned row's syncOutputs[3]: \(pinnedOutputs[3])"
            )

            let heldOutputs = try syncOutputs(try await runChecked(heldCycleRow(), cell))
            let afterLeave = heldOutputs.filter { $0.afterPass == leavePass }.map(\.kind)
            #expect(!afterLeave.contains("tick"), "the leave's turn ran its sync phase under the held cycle: \(afterLeave)")
        }

        /// disconnect-during-keeper-join with a legacy cycle held at `cycleBeforeEndSync` while
        /// the leave's turn runs: the order the flake hit by chance, forced.
        private func heldCycleRow() -> DiffScenario {
            var steps: [DiffStep] = witnessJoins
            steps += [
                .connect("A", session: "s-a"),
                .arm(.keeper(.join)),
                .startJoin("A", player: "pa"),
                .reach(.keeper(.join)),
                .observe(.adapter(.membershipQueued)),
                .startDisconnect("A"),
                .reach(.adapter(.membershipQueued)),
                .arm(.keeper(.leave)),
                .release(.keeper(.join)),
                .reach(.keeper(.leave)),
            ]
            // A cycle in flight that owns the keeper's sync flag. The writer has no backlog, so
            // `syncNow` doesn't take the backlog branch.
            steps += [
                .flushOutbound,
                .arm(.adapter(.cycleBeforeEndSync), arrival: nil),
                .spawn("a legacy cycle") { run in await run.adapter.syncNow() },
                .reach(.adapter(.cycleBeforeEndSync)),
            ]
            // The leave's turn runs under the cycle and returns. It left its sync phase to the
            // sync-only turn after the cycle's `endSync`.
            steps += [
                .release(.keeper(.leave)),
                .awaitDisconnectForwards,
                .check("the leave's turn deferred its sync to the cycle's end") { run in
                    try expect(!(await run.keeper.currentState().players.contains("pa")), "OnLeave hasn't run")
                    try expect(await run.keeper.syncOnlyTurnAfterLegacyCycleForTesting, "the latch isn't set")
                },
            ]
            // The cycle ends, and `endSync` starts that turn in a task of its own: held, then let
            // go once the cycle's caller has returned. Where its output lands in the record isn't
            // pinned, so the test doesn't read it.
            steps += [
                .arm(.keeper(.syncOnlyAfterLegacyCycle)),
                .release(.adapter(.cycleBeforeEndSync)),
                .reach(.keeper(.syncOnlyAfterLegacyCycle)),
                .awaitSpawned,
                .release(.keeper(.syncOnlyAfterLegacyCycle)),
                .awaitJoin("A"),
                .settleDisconnects,
                .liveCheckpoint,
                .disconnect("B"),
            ]
            return DiffScenario(
                name: "disconnect-during-keeper-join-held-cycle",
                cells: .inTurnOnly,
                steps: steps,
                outcomes: ["join-B": .reply, "join-A": .none],
                lifecycle: ["pb": [.join, .leave], "pa": [.join, .leave]]
            )
        }

        /// One recorded sync output's turn kind and read position.
        private struct SyncOutput: Equatable, CustomStringConvertible {
            let kind: String
            let afterPass: Int64?
            let sequence: Int64?
            var description: String { "\(kind) afterPass \(afterPass.map(String.init) ?? "-") sequence \(sequence.map(String.init) ?? "-")" }
        }

        /// The record's sync outputs (tickless frame 0), in stream order.
        private func syncOutputs(_ result: DiffRunResult) throws -> [SyncOutput] {
            guard case .object(let root) = result.record.decoded,
                  case .array(let frames)? = root["frames"],
                  case .object(let frame)? = frames.first,
                  case .array(let outputs)? = frame["syncOutputs"]
            else { throw DiffRunFailure("the record has no sync outputs") }
            return try outputs.map { output in
                guard case .object(let fields) = output, case .string(let kind)? = fields["turnKind"] else {
                    throw DiffRunFailure("a sync output has no turn kind")
                }
                func integer(_ key: String) -> Int64? {
                    if case .int(let value)? = fields[key] { return value }
                    return nil
                }
                return SyncOutput(kind: kind, afterPass: integer("afterPass"), sequence: integer("sequence"))
            }
        }
    }
}
#endif
