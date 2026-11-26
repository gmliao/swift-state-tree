// Tests/SwiftStateTreeTests/TestBounds.swift
//
// One scale for the wall-clock bounds that turn a hang into a failure. The bound is a limit on
// how long a hold may take to be reached, not a measurement: a healthy run ends at the hold, so
// a longer bound costs nothing there. A slow runner (a loaded or virtualized Windows runner
// stalls for seconds) needs a longer one, or a hold that is only late reads as a hang (#888).

import Foundation
import SwiftStateTree

enum TestBounds {
    /// The environment variable that selects the slow scale. The Windows job sets it to `1`;
    /// a developer on a slow machine can set it too.
    static let slowRunnerKey = "SST_SLOW_RUNNER"

    /// How long a test waits for a hold, a signal or a shutdown before it records a hang.
    /// 10 s by default; 30 s when `SST_SLOW_RUNNER` is true. The slow scale stays well under the
    /// suites' one-minute time limit, so a real hang names its step before the limit ends it.
    static let hang: Duration = EnvHelpers.getEnvBool(key: slowRunnerKey, defaultValue: false)
        ? .seconds(30) : .seconds(10)
}
