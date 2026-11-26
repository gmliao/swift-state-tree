// Tests/SwiftStateTreeNIOTests/Differential/DifferentialHarnessTests.swift
//
// The differential harness's suite (#555): every scenario in every cell its rule names, checked
// by the property oracle and compared with its golden. With `SST_UPDATE_GOLDEN=1` (the recorder
// script only) it writes candidates instead of comparing.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeTestSupport

/// Runs a scenario in a cell and checks the oracle; a failure names both.
func runChecked(_ scenario: DiffScenario, _ cell: DiffCell) async throws -> DiffRunResult {
    do {
        let result = try await DiffRun.make(scenario, cell: cell).execute()
        // The oracle's failures name the run's deferrals too (#908).
        let diagnostics = result.diagnostics.summary.isEmpty ? "" : " (\(result.diagnostics.summary))"
        do {
            try DiffOracle.outcomes(scenario, result, cell: cell)
            try DiffOracle.lifecycle(scenario, result)
            guard result.record.complete else { throw DiffRunFailure("the record is incomplete") }
        } catch let failure as DiffRunFailure {
            throw DiffRunFailure("\(failure)\(diagnostics)")
        }
        return result
    } catch let failure as DiffRunFailure {
        throw DiffRunFailure("\(scenario.name) \(cell): \(failure)")
    }
}

/// One pass over every scenario's cells: run, read the golden, compare, and judge against the
/// expected differences. The run and the golden read are passed in, so a self-check can drive
/// the pass. A cell that throws is recorded and the pass goes on: every later cell is still
/// compared and reported, and the summary says how many threw.
enum DiffSweep {
    /// The scenarios that hold the writer with the back-pressure override: the only ones whose
    /// runs may defer a sync phase, and each of them must.
    static let scenariosForcingBackPressure: Set<String> = ["join-during-writer-backlog"]

    struct Report {
        /// Cells run (not replaced), whether or not they threw.
        var ran = 0
        /// Cells whose run returned and whose golden was read and compared.
        var compared = 0
        var replaced = 0
        /// `<scenario> <cell>: <error>`, for each cell whose run threw.
        var threw: [String] = []
        /// Every failure, in order, as the test records it.
        var issues: [String] = []
        var bytesCompared = true
    }

    static func run(
        scenarios: [DiffScenario],
        retired: [DiffRetiredRow],
        expected: [DiffExpectedDifference],
        toolchain: String,
        execute: (DiffScenario, DiffCell) async throws -> DiffRunResult,
        readGolden: (String) throws -> DiffGoldenFile
    ) async -> Report {
        var report = Report()
        var replacements: [String: DiffRetiredRow] = [:]
        for row in retired {
            for cell in row.cells { replacements["\(row.scenario).\(cell)"] = row }
        }
        for scenario in scenarios {
            for cell in scenario.cells.cells {
                if let row = replacements["\(scenario.name).\(cell)"] {
                    report.replaced += 1
                    do {
                        try await row.replacement()
                    } catch {
                        report.issues.append("\(scenario.name) \(cell), retired (\(row.reason)): its replacement failed: \(error)")
                    }
                    continue
                }
                report.ran += 1
                let name = DiffGolden.fileName(scenario, cell)
                let actual: DiffRunResult
                do {
                    actual = try await execute(scenario, cell)
                } catch {
                    report.threw.append("\(scenario.name) \(cell): \(error)")
                    report.issues.append("\(scenario.name) \(cell) threw; the sweep goes on: \(error)")
                    continue
                }
                let golden: DiffGoldenFile
                do {
                    golden = try readGolden(name)
                } catch {
                    report.issues.append("\(name): \(error)")
                    continue
                }
                if let corruption = DiffGolden.corruption(of: golden.result) {
                    report.issues.append("\(name) is corrupt: \(corruption)")
                    continue
                }
                let checkBytes = golden.recordedWith.toolchain == toolchain
                report.bytesCompared = report.bytesCompared && checkBytes
                report.compared += 1
                let differences = DiffCompare.differences(golden.result, actual, checkBytes: checkBytes)
                let entries = expected.filter { $0.scenario == scenario.name && $0.cell == cell }
                let (unexpected, stale) = DiffBranchLists.judge(differences, entries: entries, checkBytes: checkBytes)
                if !unexpected.isEmpty {
                    // Timing-dependent counters of the run, beside its differences (#908).
                    let diagnostics = actual.diagnostics.summary
                    report.issues.append("\(name):\n\(unexpected.map(\.description).joined(separator: "\n"))"
                        + (diagnostics.isEmpty ? "" : "\n(\(diagnostics))"))
                }
                // The harness drains the writer before and after each sync it runs, so no phase
                // finds it busy unless a scenario forces the back-pressure itself (#917); a
                // scenario that forces it must still see a deferral, or it stopped forcing.
                let deferred = actual.diagnostics.syncPhasesDeferredByBackPressure
                if scenariosForcingBackPressure.contains(scenario.name) {
                    if deferred == 0 {
                        report.issues.append("\(name): no sync phase was deferred, in a scenario that forces the writer's back-pressure")
                    }
                } else if deferred > 0 {
                    report.issues.append("\(name): \(actual.diagnostics.summary), in a scenario that doesn't force the writer's back-pressure")
                }
                if !stale.isEmpty {
                    report.issues.append("\(name): stale expected difference(s): \(stale.map { "\($0.checkpoint) \($0.channel.rawValue) \($0.place) (\($0.reason))" })")
                }
            }
        }
        return report
    }
}

/// The parent of the harness's two suites. Both share the process-wide resolver gates
/// (`DiffGates`), and a suite's `.serialized` orders only its own tests: as siblings under one
/// serialized parent, no test of one suite runs beside a test of the other.
@Suite(.serialized)
enum DifferentialHarness {}

extension DifferentialHarness {
    @Suite("Differential harness (#555)", .resolverDeadlinesOff)
    struct DifferentialHarnessTests {
        @Test("Every scenario in every cell passes the oracle and matches its golden")
        func scenariosMatchTheirGoldens() async throws {
            if let refusal = DiffGolden.updateRefusal(environment: DiffGolden.environment) {
                Issue.record(Comment(rawValue: refusal))
                return
            }
            if DiffGolden.isUpdating {
                try await record()
                return
            }
            let index = try DiffGolden.readIndex()
            let listProblems = DiffBranchLists.problems(
                expected: diffExpectedDifferences, retired: diffRetiredRows, indexFiles: index.files
            )
            #expect(listProblems.isEmpty, "the branch lists: \(listProblems.joined(separator: "; "))")
            guard listProblems.isEmpty else { return }
            let report = await DiffSweep.run(
                scenarios: diffScenarios,
                retired: diffRetiredRows,
                expected: diffExpectedDifferences,
                toolchain: DiffGolden.toolchain,
                execute: { try await runChecked($0, $1) },
                readGolden: { try DiffGolden.read(named: $0) }
            )
            for issue in report.issues { Issue.record(Comment(rawValue: issue)) }
            // Fail closed: every cell the index lists ran or was replaced.
            let listed = index.files.count
            print("Differential harness: \(report.ran) cell(s) run, \(report.compared) compared, \(report.threw.count) threw, \(report.replaced) replaced, \(listed) listed")
            #expect(report.ran > 0, "no cell ran")
            #expect(report.ran > 0 && report.ran + report.replaced == listed, "\(report.ran) ran and \(report.replaced) replaced; the index lists \(listed)")
            if !report.bytesCompared {
                print("Differential harness: decoded views only, on \(DiffGolden.toolchain); the goldens were recorded on another toolchain. The pinned-image CI jobs compare bytes and are the gate.")
            }
        }

        @Test("The golden index lists every scenario and cell, and the folder holds nothing else")
        func indexMatchesTheScenarios() throws {
            guard !DiffGolden.isUpdating else { return }
            let expected = DiffGolden.expectedFiles(diffScenarios)
            let index = try DiffGolden.readIndex()
            #expect(index.files == expected, "the index isn't the scenarios' set")
            let present = DiffGolden.presentFiles()
            #expect(Set(expected).subtracting(present).sorted() == [], "golden files missing")
            #expect(Set(present).subtracting(expected).sorted() == [], "golden files no scenario claims")
        }

        /// One candidate set: every scenario and cell, oracle-checked, each file's decoded views
        /// checked against its bytes, then the index.
        private func record() async throws {
            let folder = try DiffGolden.outputFolder()
            let recordedWith = DiffRecordedWith(
                commit: DiffGolden.environment[DiffGoldenKeys.commit] ?? "unknown", toolchain: DiffGolden.toolchain
            )
            for scenario in diffScenarios {
                for cell in scenario.cells.cells {
                    let result = try await runChecked(scenario, cell)
                    if let corruption = DiffGolden.corruption(of: result) {
                        throw DiffRunFailure("\(scenario.name) \(cell): \(corruption)")
                    }
                    let file = DiffGoldenFile(scenario: scenario.name, cell: cell.description, recordedWith: recordedWith, result: result)
                    try DiffGolden.write(file, named: DiffGolden.fileName(scenario, cell), to: folder)
                }
            }
            try DiffGolden.writeIndex(diffScenarios, to: folder)
        }
    }
}
#endif
