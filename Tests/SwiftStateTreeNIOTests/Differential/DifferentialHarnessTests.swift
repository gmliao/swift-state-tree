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
        try DiffOracle.outcomes(scenario, result, cell: cell)
        try DiffOracle.lifecycle(scenario, result)
        guard result.record.complete else { throw DiffRunFailure("the record is incomplete") }
        return result
    } catch let failure as DiffRunFailure {
        throw DiffRunFailure("\(scenario.name) \(cell): \(failure)")
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
            var replacements: [String: DiffRetiredRow] = [:]
            for row in diffRetiredRows {
                for cell in row.cells { replacements["\(row.scenario).\(cell)"] = row }
            }
            var bytesCompared = true
            var ran = 0
            var masked = 0
            var replaced = 0
            for scenario in diffScenarios {
                for cell in scenario.cells.cells {
                    // The adapter's in-turn sync is the config's and `IN_TURN_SYNC`'s: with the env
                    // off, an in-turn cell would run legacy, so it is masked, and counted.
                    if cell.sync == .inTurn && !InTurnSync.isEnabled() {
                        masked += 1
                        continue
                    }
                    if let row = replacements["\(scenario.name).\(cell)"] {
                        replaced += 1
                        do {
                            try await row.replacement()
                        } catch {
                            Issue.record("\(scenario.name) \(cell), retired (\(row.reason)): its replacement failed: \(error)")
                        }
                        continue
                    }
                    ran += 1
                    let name = DiffGolden.fileName(scenario, cell)
                    let actual = try await runChecked(scenario, cell)
                    let golden: DiffGoldenFile
                    do {
                        golden = try DiffGolden.read(named: name)
                    } catch {
                        Issue.record("\(name): \(error)")
                        continue
                    }
                    if let corruption = DiffGolden.corruption(of: golden.result) {
                        Issue.record("\(name) is corrupt: \(corruption)")
                        continue
                    }
                    let checkBytes = golden.recordedWith.toolchain == DiffGolden.toolchain
                    bytesCompared = bytesCompared && checkBytes
                    let differences = DiffCompare.differences(golden.result, actual, checkBytes: checkBytes)
                    let entries = diffExpectedDifferences.filter { $0.scenario == scenario.name && $0.cell == cell }
                    let (unexpected, stale) = DiffBranchLists.judge(differences, entries: entries, checkBytes: checkBytes)
                    #expect(unexpected.isEmpty, "\(name):\n\(unexpected.map(\.description).joined(separator: "\n"))")
                    #expect(stale.isEmpty, "\(name): stale expected difference(s): \(stale.map { "\($0.checkpoint) \($0.channel.rawValue) \($0.place) (\($0.reason))" })")
                }
            }
            // Fail closed: every cell the index lists ran, was replaced, or was masked.
            let listed = index.files.count
            print("Differential harness: \(ran) cell(s) compared, \(masked) masked (IN_TURN_SYNC), \(replaced) replaced, \(listed) listed")
            #expect(ran > 0, "no cell ran")
            #expect(ran + masked + replaced == listed, "\(ran) ran, \(replaced) replaced and \(masked) masked; the index lists \(listed)")
            if !bytesCompared {
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
            guard InTurnSync.isEnabled() else {
                throw DiffRunFailure("recording needs the full matrix: IN_TURN_SYNC=false would mask the in-turn cells")
            }
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
