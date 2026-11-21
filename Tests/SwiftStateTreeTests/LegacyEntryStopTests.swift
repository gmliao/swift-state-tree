// Tests/SwiftStateTreeTests/LegacyEntryStopTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

private let legacyStopMessage = "no live keeper takes the legacy path"

private func standardError(_ result: ExitTest.Result?) -> String {
    guard let result else { return "" }
    return String(decoding: result.standardErrorContent, as: UTF8.self)
}

/// The legacy pass entries stay until L2d-3, reachable only by a re-evaluation keeper. On a live
/// keeper each stops the process (`precondition`). Exit tests, so a routing change that sends a
/// live keeper there fails these by name instead of ending the test run.
@Suite("Legacy pass entries stop on a live keeper (#546 L2d-2)", .timeLimit(.minutes(1)))
struct LegacyEntryStopTests {
    @Test("runTicklessJobPass on a live keeper stops the process")
    func ticklessJobPassStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(), autoStartLoops: false
            )
            await keeper.runTicklessJobPassForTesting()
        }
        // `precondition` prints its message only in debug builds.
        #if DEBUG
        #expect(standardError(result).contains(legacyStopMessage))
        #endif
        _ = result
    }

    @Test("runLegacyPass on a live keeper stops the process")
    func legacyPassStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let keeper = LandKeeper<RoutingPinState>(
                definition: makeRoutingPinLand(tick: false), initialState: RoutingPinState(), autoStartLoops: false
            )
            _ = try? await keeper.runLegacyPassForTesting(sequence: 0)
        }
        #if DEBUG
        #expect(standardError(result).contains(legacyStopMessage))
        #endif
        _ = result
    }
}
