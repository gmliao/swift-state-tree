import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// The cadence smoke measures real time on purpose: with running loops, state frames must come
/// near the sync interval. Run beside other tests in one process, CPU-heavy neighbours can starve
/// it, and `.serialized` orders tests only within its own suite. So it runs only with
/// `WALL_CLOCK_TESTS=1`, in a process of its own:
///
///     WALL_CLOCK_TESTS=1 swift test --no-parallel --filter WallClockCadenceSmokeTests
///
/// CI runs that as its own step in each `IN_TURN_SYNC` leg. The test sets the sync path on the
/// adapter itself (`inTurn`), so it checks both paths in either leg.
@Suite(
    "Wall-clock cadence smoke",
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled(
        if: ProcessInfo.processInfo.environment["WALL_CLOCK_TESTS"] == "1",
        "WALL_CLOCK_TESTS=1 runs it, in a process of its own"
    )
)
struct WallClockCadenceSmokeTests {
    @Test("cadence smoke (wall clock): with running loops, state frames come near the sync interval (ON and OFF)", arguments: [true, false])
    func cadenceSmokeWallClock(inTurn: Bool) async throws {
        let report = try await TransportAdapterInTurnSyncTests.measureCadence(inTurn: inTurn, duration: .milliseconds(1200))
        if ProcessInfo.processInfo.environment["CADENCE_REPORT"] == "1" {
            print("CADENCE \(report.summary)")
        }
        try #require(report.gaps.count >= 10, "state frames: \(report.gaps.count + 1)")
        // Tolerance: half to twice the 50 ms interval, on the median only (scheduler jitter on
        // shared runners; tails belong to the perf A/B). The message names the mechanism behind
        // each long gap, so a miss on CI says which one fired (#164).
        let median = report.gaps.sorted()[report.gaps.count / 2]
        #expect(median > .milliseconds(25) && median < .milliseconds(100), "median \(median): \(report.summary)")
    }
}
