// Tests/SwiftStateTreeNIOTests/Differential/DifferentialHarnessTests.swift
//
// The differential harness's suite (#555): every scenario in every cell its rule names.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO
import SwiftStateTreeTestSupport

@Suite("Differential harness (#555)", .serialized, .resolverDeadlinesOff)
struct DifferentialHarnessTests {
    @Test("A scenario runs the same twice in one process, in every cell")
    func sameTwice() async throws {
        for scenario in diffScenarios {
            for cell in scenario.cells.cells {
                let first = try await DiffRun.make(scenario, cell: cell).execute()
                let second = try await DiffRun.make(scenario, cell: cell).execute()
                let differences = DiffCompare.differences(first, second)
                #expect(differences.isEmpty, "\(scenario.name) \(cell): \(differences.map(\.description).joined(separator: "\n"))")
                #expect(first.record.complete, "\(scenario.name) \(cell): the record is complete")
                #expect(!first.live.connections.isEmpty)
            }
        }
    }
}
#endif
