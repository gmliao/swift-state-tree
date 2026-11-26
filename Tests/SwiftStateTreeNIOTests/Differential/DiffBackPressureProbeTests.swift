// The back-pressure probe (#917): what a sync phase deferred by the writer's back-pressure
// does to a run. For each scenario and in-turn cell it runs the scenario once with nothing
// forced (the baseline) and counts the reads of the in-turn back-pressure rule. Then, for each
// k in 1...reads, it forces the rule busy from the k-th read: m=1 holds that one read busy (one
// phase deferred); m=2 holds the rule busy for 50 reads (the drain wait's included), so the
// phase the harness runs next is deferred too. It compares each run with the baseline of the
// same process.
//
// Run it (about 7 minutes for both lands and 5 repeats, debug, on a laptop):
//
//     DIFF_BACKPRESSURE_PROBE=1 [DIFF_BACKPRESSURE_PROBE_LAND=tick|tickless] \
//         [DIFF_BACKPRESSURE_PROBE_REPEATS=5] swift test --filter DiffBackPressureProbeTests
//
// It prints one `probe917` line per window whose runs weren't all `same`, with the classes'
// distribution over the repeats, and a tally per land and m. The classes:
// - `same`: the run equals the baseline.
// - `merged`: the record has fewer sync outputs (two deferred requests shared one retry).
// - `extra`: the record has more sync outputs.
// - `kind`: the same count, and an output's turn kind changed (a tick output became
//   sync-only, delivered by the retry or the next sync).
// - `outputs`: the same count and kinds; another field of an output changed.
// - `clients`: the outputs are equal; a client's frames or closes differ.
// - `record`: only another field of the record differs.
// - `threw`: the run failed one of the scenario's own checks, whose precondition the forced
//   deferral broke (for example "A1 didn't flip before its leave"); not a harness crash.
// A class with ` deferred=N` had N deferrals instead of m: the writer was really busy as well
// (the scenario forces it), or a burst deferred one phase, or more than two.

#if DEBUG
import Foundation
import Testing
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import SwiftStateTree
@testable import SwiftStateTreeNIO

enum DiffBackPressureProbeEnvKeys {
    static let enabled = "DIFF_BACKPRESSURE_PROBE"
    /// `tick`, `tickless`, or unset for both.
    static let land = "DIFF_BACKPRESSURE_PROBE_LAND"
    /// Runs of each (scenario, cell, k, m), for a stress pass.
    static let repeats = "DIFF_BACKPRESSURE_PROBE_REPEATS"
}

/// Back-pressure that the probe forces at the k-th read of the in-turn rule. With `burst` 1 only
/// that read is busy: one phase is deferred, and the writer-drain retry finds the writer free.
/// With a larger burst the rule stays busy for that many reads in all, the drain wait's reads
/// (about 1 ms apart) included, so a phase the harness runs right after the deferred one is
/// deferred too; the run's diagnostic counts how many were. Before the window opens only phases
/// read the rule (no retry is pending unless the writer was really busy, which the diagnostic
/// also shows).
private final class DeferralWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Int
    private let burst: Int
    private var reads = 0

    init(start: Int, burst: Int) {
        self.start = start
        self.burst = burst
    }

    var readCount: Int { lock.withLock { reads } }

    func busy() -> Bool {
        lock.withLock {
            reads += 1
            return reads >= start && reads < start + burst
        }
    }
}

// Under the harness's serialized parent: the probe and the harness suites both reset the
// process-wide resolver gates (`DiffGates`), so they must not run side by side.
extension DifferentialHarness {
    @Suite(
        "PROBE #917: deferred sync phases against a baseline",
        .enabled(if: EnvHelpers.getEnvBool(key: DiffBackPressureProbeEnvKeys.enabled, defaultValue: false)),
        .resolverDeadlinesOff,
        .serialized
    )
    struct DiffBackPressureProbeTests {
        private struct Output: Equatable, CustomStringConvertible {
            let kind: String
            let afterPass: Int64?
            let sequence: Int64?
            var description: String { "(\(kind) p\(afterPass.map(String.init) ?? "-") s\(sequence.map(String.init) ?? "-"))" }
        }

        /// Every frame's sync outputs, in order.
        private static func outputs(_ result: DiffRunResult) -> [Output] {
            guard case .object(let root) = result.record.decoded, case .array(let frames)? = root["frames"] else { return [] }
            return frames.flatMap { frame -> [Output] in
                guard case .object(let fields) = frame, case .array(let outputs)? = fields["syncOutputs"] else { return [] }
                return outputs.compactMap { output in
                    guard case .object(let o) = output, case .string(let kind)? = o["turnKind"] else { return nil }
                    func integer(_ key: String) -> Int64? { if case .int(let v)? = o[key] { return v }; return nil }
                    return Output(kind: kind, afterPass: integer("afterPass"), sequence: integer("sequence"))
                }
            }
        }

        private static func run(_ scenario: DiffScenario, _ cell: DiffCell, window: DeferralWindow?) async throws -> DiffRunResult {
            let run = try await DiffRun.make(scenario, cell: cell)
            if let window {
                let adapter = run.adapter
                await adapter.setWriterBackPressureOverrideForTesting { window.busy() }
            }
            return try await run.execute()
        }

        /// `same`, `merged` (fewer outputs), `kind` (same count, a turn kind changed), `outputs`
        /// (same count and kinds, other fields), `clients` (outputs equal, frames or closes differ).
        private static func classify(_ base: DiffRunResult, _ armed: DiffRunResult) -> (String, String) {
            let a = outputs(base), b = outputs(armed)
            let clients = DiffCompare.compare(base.live, armed.live, checkpoint: "live", checkBytes: false)
                + DiffCompare.compare(base.terminal, armed.terminal, checkpoint: "terminal", checkBytes: false)
            let record = DiffCompare.compareRecord(base.record, armed.record, checkBytes: false)
            let detail = "\(a) -> \(b)" + (clients.first.map { "; first client difference: \($0)" } ?? "")
            if b.count < a.count { return ("merged", detail) }
            if b.count > a.count { return ("extra", detail) }
            if a.map(\.kind) != b.map(\.kind) { return ("kind", detail) }
            if a != b { return ("outputs", detail) }
            if !clients.isEmpty { return ("clients", detail) }
            if !record.isEmpty { return ("record", "\(record.first!)") }
            return ("same", "")
        }

        @Test("PROBE #917: every deferral window on every in-turn cell")
        func sweep() async throws {
            let land = EnvHelpers.getEnvString(key: DiffBackPressureProbeEnvKeys.land, defaultValue: "")
            let repeats = max(1, EnvHelpers.getEnvInt(key: DiffBackPressureProbeEnvKeys.repeats, defaultValue: 1))
            guard land.isEmpty || DiffLandKind(rawValue: land) != nil else {
                Issue.record("DIFF_BACKPRESSURE_PROBE_LAND is \(land): tick, tickless, or unset")
                return
            }
            var tally: [String: Int] = [:]
            var lines: [String] = []
            var cells = 0
            for scenario in diffScenarios {
                for cell in scenario.cells.cells where cell.sync == .inTurn && (land.isEmpty || cell.land.rawValue == land) {
                    let counter = DeferralWindow(start: .max, burst: 0)
                    let base: DiffRunResult
                    do { base = try await Self.run(scenario, cell, window: counter) } catch {
                        // No baseline, no evidence for this cell: the probe fails.
                        Issue.record("\(scenario.name) \(cell): the baseline threw: \(error)")
                        continue
                    }
                    cells += 1
                    let reads = counter.readCount
                    tally["baseline \(cell.land.rawValue) deferred=\(base.diagnostics.syncPhasesDeferredByBackPressure)", default: 0] += 1
                    for k in 1..<(reads + 1) {
                        for m in 1...2 {
                            // The classes over the repeats: a race shows as more than one.
                            var classes: [String: Int] = [:]
                            var details: [String: String] = [:]
                            for _ in 0..<repeats {
                                let key: String
                                var detail = ""
                                var deferred = -1
                                do {
                                    let armed = try await Self.run(scenario, cell, window: DeferralWindow(start: k, burst: m == 1 ? 1 : 50))
                                    deferred = armed.diagnostics.syncPhasesDeferredByBackPressure
                                    (key, detail) = Self.classify(base, armed)
                                } catch {
                                    key = "threw"
                                    detail = "\(error)"
                                }
                                let label = key + (deferred == m || key == "threw" ? "" : " deferred=\(deferred)")
                                classes[label, default: 0] += 1
                                if details[label] == nil { details[label] = detail }
                            }
                            let distribution = classes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                            tally["\(cell.land.rawValue) m=\(m) [\(distribution.replacingOccurrences(of: #"\d+"#, with: "n", options: .regularExpression))]", default: 0] += 1
                            if classes.keys.contains(where: { $0 != "same" }) {
                                lines.append("\(scenario.name) \(cell) k=\(k)/\(reads) m=\(m) [\(distribution)]")
                                for (label, detail) in details.sorted(by: { $0.key < $1.key }) where label != "same" {
                                    lines.append("    \(label): \(detail)")
                                }
                            }
                        }
                    }
                }
            }
            #expect(cells > 0, "the probe compared no cell")
            for line in lines { print("probe917 \(line)") }
            for (label, count) in tally.sorted(by: { $0.key < $1.key }) { print("probe917 tally \(label): \(count)") }
        }
    }
}
#endif
