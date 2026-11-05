// Examples/GameDemo/Sources/GameContent/Support/ProfileRecorderEnvKeys.swift
//
// When the demo executables start Swift Profile Recorder.

import SwiftStateTree

/// Environment keys of Swift Profile Recorder, as `ProfileRecorderServerConfiguration
/// .parseFromEnvironment()` reads them.
public enum ProfileRecorderEnvKeys {
    public static let serverURL = "PROFILE_RECORDER_SERVER_URL"
    public static let serverURLPattern = "PROFILE_RECORDER_SERVER_URL_PATTERN"

    /// Whether either key is set. The executables start the profile server only then: its
    /// configuration defaults to NIO's global singleton event-loop group, and reading that
    /// configuration starts the group, one thread per machine CPU (`System.coreCount`, which
    /// ignores CPU affinity), even when no profile server runs. When profiling, the group's size
    /// can be set with NIO's `NIO_SINGLETON_GROUP_LOOP_COUNT`.
    public static var isConfigured: Bool {
        EnvHelpers.getEnvStringOptional(key: serverURL) != nil
            || EnvHelpers.getEnvStringOptional(key: serverURLPattern) != nil
    }
}
