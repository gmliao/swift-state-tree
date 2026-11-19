// Tests/SwiftStateTreeNIOTests/Differential/DiffBranchLists.swift
//
// The rewrite branch's two lists (#555, plan rev 10 "Expected differences" and "Retired rows"),
// and the rules the runner checks them by. The lists themselves are `ExpectedDifferences.swift`
// and `RetiredRows.swift`, unprotected; this file is protected, so the branch can't loosen the
// rules.
// - An expected difference names one cell and one difference, exactly (checkpoint, channel,
//   place and detail). Each is used once: one that matches nothing fails as stale, two for the
//   same difference fail as an overlap. One aimed at a masked cell isn't judged in that run.
// - A retired row names a scenario, its cells, the reason, a mutation witness and a replacement
//   the runner calls instead of the row. Its (scenario, cell) keys are unique, the index has each,
//   and no expected difference aims at one.

#if DEBUG
import Foundation

/// A difference the rewrite branch makes on purpose, against one cell's golden.
struct DiffExpectedDifference: Sendable {
    let scenario: String
    let cell: DiffCell
    let checkpoint: String
    let channel: DiffDifference.Channel
    let place: String
    let detail: String
    /// Why the branch differs, with its issue.
    let reason: String

    var key: String { "\(scenario).\(cell)" }

    func matches(_ difference: DiffDifference) -> Bool {
        difference.checkpoint == checkpoint && difference.channel == channel
            && difference.place == place && difference.detail == detail
    }
}

/// A row the rewrite retires, with the test that replaces it.
struct DiffRetiredRow: Sendable {
    let scenario: String
    let cells: [DiffCell]
    let reason: String
    /// The source mutant that breaks the invariant the row protected; the replacement fails on it.
    let witness: String
    let replacement: @Sendable () async throws -> Void
}

enum DiffBranchLists {
    /// What's wrong with the two lists against the index's files, or nothing.
    static func problems(
        expected: [DiffExpectedDifference], retired: [DiffRetiredRow], indexFiles: [String]
    ) -> [String] {
        var problems: [String] = []
        let indexed = Set(indexFiles.map { $0.hasSuffix(".json") ? String($0.dropLast(5)) : $0 })
        var retiredKeys = Set<String>()
        for row in retired {
            if row.cells.isEmpty { problems.append("retired \(row.scenario) names no cell") }
            if row.witness.isEmpty { problems.append("retired \(row.scenario) names no witness") }
            for cell in row.cells {
                let key = "\(row.scenario).\(cell)"
                if !retiredKeys.insert(key).inserted { problems.append("retired \(key) is listed twice") }
                if !indexed.contains(key) { problems.append("retired \(key) isn't in the index") }
            }
        }
        for entry in expected {
            if !indexed.contains(entry.key) { problems.append("expected difference for \(entry.key), which isn't in the index") }
            if retiredKeys.contains(entry.key) { problems.append("expected difference for \(entry.key), which is retired") }
        }
        for (i, a) in expected.enumerated() {
            for b in expected[(i + 1)...] where a.key == b.key && a.checkpoint == b.checkpoint
                && a.channel == b.channel && a.place == b.place && a.detail == b.detail {
                problems.append("two expected differences for \(a.key) \(a.checkpoint) \(a.channel.rawValue) \(a.place)")
            }
        }
        return problems
    }

    /// One cell's comparison against its entries: the differences no entry covers, and the
    /// entries that covered nothing (stale).
    static func judge(
        _ differences: [DiffDifference], entries: [DiffExpectedDifference]
    ) -> (unexpected: [DiffDifference], stale: [DiffExpectedDifference]) {
        var used = Array(repeating: false, count: entries.count)
        var unexpected: [DiffDifference] = []
        for difference in differences {
            if let i = entries.indices.first(where: { !used[$0] && entries[$0].matches(difference) }) {
                used[i] = true
            } else {
                unexpected.append(difference)
            }
        }
        let stale = entries.indices.filter { !used[$0] }.map { entries[$0] }
        return (unexpected, stale)
    }
}
#endif
