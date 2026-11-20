// Tests/SwiftStateTreeNIOTests/Differential/DiffLeaveTurnTests.swift
//
// #676: in disconnect-during-keeper-join on a tickless land, the queued leave runs its own input
// turn once the held join returns. A legacy sync cycle that holds the keeper's sync flag while
// that turn runs moves the turn's sync phase into a sync-only turn after the cycle's `endSync`,
// so the record's output after the leave's pass reads `syncOnly` instead of `tick`. The row pins
// the order with `awaitDisconnectForwards`. This test holds a cycle open over the leave's turn
// and checks that the record then shows the flake's signature, and that the pinned row doesn't.

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

        @Test("A legacy cycle held over the leave's turn makes its sync a sync-only turn; the pinned row keeps it in the turn")
        func heldCycleMovesTheLeaveSync() async throws {
            // The in-turn cell is masked with IN_TURN_SYNC=false.
            guard InTurnSync.isEnabled() else { return }

            let pinned = try #require(diffScenarios.first { $0.name == "disconnect-during-keeper-join" })
            let pinnedKinds = try turnKinds(afterPass: leavePass, try await runChecked(pinned, cell))
            #expect(pinnedKinds.first == "tick", "the pinned row's output after the leave's pass: \(pinnedKinds)")
            #expect(!pinnedKinds.contains("syncOnly"), "the pinned row's outputs after the leave's pass: \(pinnedKinds)")

            let heldKinds = try turnKinds(afterPass: leavePass, try await runChecked(heldCycleRow(), cell))
            #expect(heldKinds.contains("syncOnly"), "no sync-only output after the leave's pass: \(heldKinds)")
            #expect(!heldKinds.contains("tick"), "the leave's turn ran its sync phase under the held cycle: \(heldKinds)")
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
            // The leave's turn runs under the cycle and returns; then the cycle ends.
            steps += [
                .release(.keeper(.leave)),
                .awaitDisconnectForwards,
                .release(.adapter(.cycleBeforeEndSync)),
                .awaitSpawned,
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

        /// The turn kinds of the record's sync outputs after tickless pass `pass`, in stream order.
        private func turnKinds(afterPass pass: Int64, _ result: DiffRunResult) throws -> [String] {
            guard case .object(let root) = result.record.decoded,
                  case .array(let frames)? = root["frames"],
                  case .object(let frame)? = frames.first,
                  case .array(let outputs)? = frame["syncOutputs"]
            else { throw DiffRunFailure("the record has no sync outputs") }
            return outputs.compactMap { output in
                guard case .object(let fields) = output,
                      case .string(let kind)? = fields["turnKind"],
                      case .int(let after)? = fields["afterPass"], after == pass
                else { return nil }
                return kind
            }
        }
    }
}
#endif
