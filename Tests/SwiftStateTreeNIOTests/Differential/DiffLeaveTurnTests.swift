// Tests/SwiftStateTreeNIOTests/Differential/DiffLeaveTurnTests.swift
//
// #676: in disconnect-during-keeper-join on a tickless land, the queued leave runs its own input
// turn once the held join returns. A legacy sync cycle that held the keeper's sync flag while
// that turn ran moved the turn's sync phase into a sync-only turn after the cycle's `endSync`,
// so the record's output after the leave's pass read `syncOnly` instead of `tick`. The row pins
// the order with `awaitDisconnectForwards` (and a flush before the leave, against the writer's
// back-pressure). This test checks the pinned row's first output after the leave's pass (at
// the flake's index, `syncOutputs[3]`, then).
//
// Its other half held a legacy cycle over the leave's turn and checked the latch. Since #546 L2a
// an in-turn `syncNow()` is a sync-only turn, so no legacy cycle can be held there; that half is
// retired with `join-during-sync-cycle-inturn`.
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
    @Suite("Differential harness: the leave's turn (#676)", .resolverDeadlinesOff)
    struct DiffLeaveTurnTests {
        /// The cell the flake showed in.
        private let cell = DiffCell(sync: .inTurn, encoding: .messagepack, land: .tickless)
        /// B's join is pass 1, A's join pass 2, and A's leave pass 3.
        private let leavePass: Int64 = 3

        @Test("The pinned row keeps the leave's sync in its turn")
        func pinnedRowKeepsTheLeaveSyncInItsTurn() async throws {
            // The flake was the leave pass's first output (`syncOutputs[3]`): sequence 3, after
            // pass 3, `tick` then `syncOnly`. Found by its pass, not by its index, so an output
            // that a deferral moves or merges earlier in the stream (#908) doesn't hide it.
            let pinned = try #require(diffScenarios.first { $0.name == "disconnect-during-keeper-join" })
            let result = try await runChecked(pinned, cell)
            let pinnedOutputs = try syncOutputs(result)
            // The run's back-pressure deferrals, when there were any: a deferral can move or
            // merge an output (#908).
            let diagnostics = result.diagnostics.summary.isEmpty ? "" : " (\(result.diagnostics.summary))"
            let leaveOutput = try #require(
                pinnedOutputs.first { $0.afterPass == leavePass },
                "the pinned row has no output after the leave's pass: \(pinnedOutputs)\(diagnostics)"
            )
            #expect(
                leaveOutput == SyncOutput(kind: "tick", afterPass: leavePass, sequence: 3),
                "the pinned row's first output after the leave's pass: \(leaveOutput)\(diagnostics)"
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
