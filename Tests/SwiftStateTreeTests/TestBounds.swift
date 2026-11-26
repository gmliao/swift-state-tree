// Tests/SwiftStateTreeTests/TestBounds.swift
//
// One scale for the wall-clock bounds that turn a hang into a failure. The bound is a limit on
// how long a hold may take to be reached, not a measurement: a healthy run ends at the hold, so
// a longer bound costs nothing there. A slow runner (a loaded or virtualized Windows runner
// stalls for seconds) needs a longer one, or a hold that is only late reads as a hang (#888).

import Foundation

enum TestBounds {
    /// How long a test waits for a hold, a signal or a shutdown before it records a hang.
    /// 10 s by default; 60 s when `SST_SLOW_RUNNER=1` is set, and on Windows.
    static let hang: Duration = slowRunner ? .seconds(60) : .seconds(10)

    private static let slowRunner: Bool = {
        // The Windows job runs on shared runners that stall for seconds, and this test target
        // can't set an environment variable for that one job (workflows are out of scope for
        // #888), so Windows is checked here as well as the variable.
        #if os(Windows)
        return true
        #else
        return ProcessInfo.processInfo.environment["SST_SLOW_RUNNER"] == "1"
        #endif
    }()
}
