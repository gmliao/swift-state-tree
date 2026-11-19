// Tests/SwiftStateTreeNIOTests/Differential/DiffSelfCheckTests.swift
//
// Checks of the harness itself (#555, plan §7): the comparator reports every transform of one
// side (c); a golden whose decoded view isn't its bytes is corrupt, and a record whose bytes
// differ while no field does fails (d); the scenario set is well formed (cell rule, names,
// vacuity) (g). Determinism (a) is the recorder's five processes; the mutants (b, f) are run by
// hand, with their output in the PR.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

extension DifferentialHarness {
    @Suite("Differential harness self-checks (#555)", .resolverDeadlinesOff)
    struct DiffSelfCheckTests {
        /// One real run, the transforms' base: two players, so frames, events and a close exist.
        private func baseRun() async throws -> DiffRunResult {
            let scenario = try #require(diffScenarios.first { $0.name == "two-players" })
            // A legacy cell: it runs as itself under IN_TURN_SYNC=false too.
            return try await runChecked(scenario, DiffCell(sync: .legacy, encoding: .json, land: .tickless))
        }

        @Test("The comparator reports a dropped frame, a swap, a changed close, a dropped record entry")
        func comparatorIsStrict() async throws {
            let base = try await baseRun()
            #expect(DiffCompare.differences(base, base).isEmpty)

            let name = try #require(base.terminal.connections.keys.sorted().first)
            var connection = try #require(base.terminal.connections[name])
            try #require(connection.frames.count >= 2)

            var dropped = base
            connection.frames.removeLast()
            dropped.terminal.connections[name] = connection
            #expect(DiffCompare.differences(base, dropped).contains { $0.channel == .frames && $0.place == name })

            var swapped = base
            var frames = try #require(base.terminal.connections[name]).frames
            let pair = try #require(frames.indices.dropLast().first { frames[$0] != frames[$0 + 1] })
            frames.swapAt(pair, pair + 1)
            swapped.terminal.connections[name]?.frames = frames
            #expect(DiffCompare.differences(base, swapped).contains { $0.channel == .frames && $0.place == name })

            // The swap changes two frames: each is its own difference, so an expected difference
            // for the first can't cover the second. With bytes compared, each names both digests.
            let swappedFrames = DiffCompare.differences(base, swapped).filter {
                $0.checkpoint == "terminal" && $0.channel == .frames && $0.place == name
            }
            #expect(swappedFrames.count == 2, "\(swappedFrames)")
            #expect(swappedFrames.allSatisfy { $0.digests?.hasPrefix("fnv64:") == true })
            if let first = swappedFrames.first {
                let entry = DiffExpectedDifference(
                    scenario: "two-players", cell: DiffCell(sync: .legacy, encoding: .json, land: .tickless),
                    checkpoint: first.checkpoint, channel: first.channel, place: first.place,
                    detail: first.detail, digests: first.digests, reason: "self-check"
                )
                let judged = DiffBranchLists.judge(swappedFrames, entries: [entry])
                #expect(judged.unexpected.count == 1 && judged.stale.isEmpty)
                // Other bytes with the same decoded frame don't match the entry.
                var otherBytes = first
                otherBytes.digests = "fnv64:0000000000000000 vs fnv64:0000000000000000"
                #expect(!entry.matches(otherBytes))
                // A decoded-only run matches the entry without its digests.
                let decoded = DiffCompare.differences(base, swapped, checkBytes: false).filter {
                    $0.checkpoint == "terminal" && $0.channel == .frames && $0.place == name
                }
                #expect(decoded.count == 2 && decoded.allSatisfy { $0.digests == nil })
                let decodedJudged = DiffBranchLists.judge(decoded, entries: [entry], checkBytes: false)
                #expect(decodedJudged.unexpected.count == 1 && decodedJudged.stale.isEmpty)
            }

            var closed = base
            closed.terminal.connections[name]?.close = DiffClose(code: 4999, reason: "mutated")
            #expect(DiffCompare.differences(base, closed).contains { $0.channel == .close && $0.place == name })

            // A note is compared: a changed value, a missing one and an extra one each differ.
            var noted = base
            noted.live.notes = ["a note": .bool(true)]
            var flipped = noted
            flipped.live.notes = ["a note": .bool(false)]
            #expect(DiffCompare.differences(noted, flipped).contains { $0.channel == .note && $0.place == "a note" })
            #expect(DiffCompare.differences(noted, base).contains { $0.channel == .note && $0.place == "a note" })
            #expect(DiffCompare.differences(base, noted).contains { $0.channel == .note && $0.place == "a note" })

            var recordDropped = base
            guard case .object(var root) = base.record.decoded, case .array(var recordFrames)? = root["frames"] else {
                Issue.record("the record has no frames")
                return
            }
            recordFrames.removeLast()
            root["frames"] = .array(recordFrames)
            recordDropped.record = DiffRecordCapture(bytes: base.record.bytes + Data([0]), decoded: .object(root), complete: true)
            // Byte mode: the bytes difference with its digests, and the field paths beside it.
            let byBytes = DiffCompare.differences(base, recordDropped).filter { $0.channel == .record }
            #expect(byBytes.contains { $0.place == DiffCompare.recordBytesPlace && $0.digests != nil })
            #expect(byBytes.contains { $0.place != DiffCompare.recordBytesPlace })
            // Decoded views only (another toolchain): the field paths, no bytes difference.
            let byFields = DiffCompare.differences(base, recordDropped, checkBytes: false).filter { $0.channel == .record }
            #expect(!byFields.isEmpty && byFields.allSatisfy { $0.place != DiffCompare.recordBytesPlace && $0.digests == nil })
        }

        @Test("Record bytes that differ while no field does fail; decoded-only comparison skips them")
        func recordBytesWithoutAField() async throws {
            let base = try await baseRun()
            var changed = base
            changed.record = DiffRecordCapture(bytes: base.record.bytes + Data([0]), decoded: base.record.decoded, complete: base.record.complete)
            #expect(DiffCompare.differences(base, changed).map(\.place) == ["<bytes>"])
            #expect(DiffCompare.differences(base, changed, checkBytes: false).isEmpty)
        }

        @Test("A golden whose decoded view isn't its bytes is corrupt")
        func corruptGolden() async throws {
            let base = try await baseRun()
            #expect(DiffGolden.corruption(of: base) == nil)

            let name = try #require(base.terminal.connections.keys.sorted().first)
            var frame = try #require(base.terminal.connections[name]?.frames.first)
            frame = try DiffFrame(bytes: frame.bytes, decodedOverride: .string("edited"))
            var edited = base
            edited.terminal.connections[name]?.frames[0] = frame
            #expect(DiffGolden.corruption(of: edited) != nil, "an edited frame view")

            var record = base
            record.record = DiffRecordCapture(bytes: base.record.bytes, decoded: .string("edited"), complete: base.record.complete)
            #expect(DiffGolden.corruption(of: record) != nil, "an edited record view")
        }

        @Test("An update under the verify key is refused")
        func updateUnderVerify() {
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.update: "1", DiffGoldenKeys.verify: "1"]) != nil)
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.update: "1"]) == nil)
            #expect(DiffGolden.updateRefusal(environment: [DiffGoldenKeys.verify: "1"]) == nil)
        }

        @Test("The branch lists: exact, one use, stale and overlap fail, retired keys exact")
        func branchListRules() {
            let cell = DiffCell(sync: .legacy, encoding: .json, land: .tickless)
            let index = ["two-players.\(cell).json", "join-act-leave.\(cell).json"]
            let difference = DiffDifference(checkpoint: "terminal", channel: .frames, place: "A", detail: "frame 3 differs")
            func entry(_ detail: String = "frame 3 differs", scenario: String = "two-players") -> DiffExpectedDifference {
                DiffExpectedDifference(scenario: scenario, cell: cell, checkpoint: "terminal", channel: .frames, place: "A", detail: detail, reason: "test")
            }
            // Exact match, used once.
            var judged = DiffBranchLists.judge([difference], entries: [entry()])
            #expect(judged.unexpected.isEmpty && judged.stale.isEmpty)
            // A near match covers nothing: the difference is unexpected and the entry stale.
            judged = DiffBranchLists.judge([difference], entries: [entry("frame 4 differs")])
            #expect(judged.unexpected.count == 1 && judged.stale.count == 1)
            // One entry covers one difference, not two.
            judged = DiffBranchLists.judge([difference, difference], entries: [entry()])
            #expect(judged.unexpected.count == 1 && judged.stale.isEmpty)
            // An unused entry is stale.
            #expect(DiffBranchLists.judge([], entries: [entry()]).stale.count == 1)
            // Overlap, a key outside the index, a retired key twice, a retired key outside the index,
            // and an expected difference on a retired cell.
            #expect(DiffBranchLists.problems(expected: [entry(), entry()], retired: [], indexFiles: index).count == 1)
            #expect(DiffBranchLists.problems(expected: [entry(scenario: "nope")], retired: [], indexFiles: index).count == 1)
            let row = DiffRetiredRow(scenario: "join-act-leave", cells: [cell, cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [row], indexFiles: index).count == 1)
            let outside = DiffRetiredRow(scenario: "nope", cells: [cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [outside], indexFiles: index).count == 1)
            let retiredTwoPlayers = DiffRetiredRow(scenario: "two-players", cells: [cell], reason: "test", witness: "w", replacement: {})
            #expect(DiffBranchLists.problems(expected: [entry()], retired: [retiredTwoPlayers], indexFiles: index).count == 1)
            let noWitness = DiffRetiredRow(scenario: "two-players", cells: [cell], reason: "test", witness: "", replacement: {})
            #expect(DiffBranchLists.problems(expected: [], retired: [noWitness], indexFiles: index).count == 1)
            // The lists on main are empty. Judged only where the protected workflow says the lists
            // are main's (`SST_DIFFERENTIAL_MAIN_LISTS=1`): the rewrite branch's PR fills them.
            if EnvHelpers.getEnvBool(key: DiffBranchLists.mainListsKey, defaultValue: false) {
                #expect(diffExpectedDifferences.isEmpty && diffRetiredRows.isEmpty, "main's lists aren't empty")
            }
        }

        @Test("Every scenario has cells, a unique name, a live checkpoint, and states its requests")
        func scenariosAreWellFormed() {
            var names = Set<String>()
            for scenario in diffScenarios {
                #expect(!scenario.cells.cells.isEmpty, "\(scenario.name) has no cells")
                #expect(names.insert(scenario.name).inserted, "\(scenario.name) is named twice")
                let checkpoints = scenario.steps.filter { if case .liveCheckpoint = $0 { return true } else { return false } }
                #expect(checkpoints.count == 1, "\(scenario.name) has \(checkpoints.count) live checkpoints")
                #expect(!scenario.outcomes.isEmpty, "\(scenario.name) states no request")
                #expect(!scenario.lifecycle.isEmpty, "\(scenario.name) states no lifecycle")
            }
            // A recorded outcome makes no claim, so each use is listed here, with its issue: one
            // can't be added without this list changing (and the PR that adds it listing it).
            var recorded: [String] = []
            for scenario in diffScenarios {
                for cell in scenario.cells.cells {
                    for (id, outcome) in scenario.outcomes(in: cell) {
                        if case .recorded(let issue) = outcome {
                            #expect(DiffOutcome.isIssueReference(issue), "\(scenario.name) \(id): \"\(issue)\" isn't an issue reference")
                            recorded.append("\(scenario.name) \(id) \(issue)")
                        }
                    }
                }
            }
            #expect(Set(recorded) == ["teardown-during-keeper-join join-A #548"], "recorded outcomes: \(Set(recorded).sorted())")
            let lifecycles = diffScenarios.flatMap { scenario in
                scenario.recordedLifecycle.map { "\(scenario.name) \($0.key) \($0.value)" }
            }
            #expect(Set(lifecycles) == ["teardown-during-keeper-join pa #548"], "recorded lifecycles: \(Set(lifecycles).sorted())")
        }
    }
}
#endif
