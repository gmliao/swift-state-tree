import Foundation

/// The debug-build check that a throwing handler didn't write state before it threw (#87).
///
/// A handler that throws keeps what it wrote before the throw, and the next sync sends it, so a
/// handler should check everything that can throw before its first write. Debug builds compare
/// the synced state before and after a throwing handler and log a warning, once per input type
/// and land, when it changed (`LandKeeper.withMutableStateSync`). Release builds don't check.
enum ThrowingInputWriteCheck {
    /// Whether the check is on: `true` unless `DEBUG_WARN_THROWING_INPUT_WRITES` is false. A
    /// large debug game can turn it off to skip the state copy it takes per input.
    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(
            key: EnvKeys.Debug.warnThrowingInputWrites,
            defaultValue: true,
            environment: environment
        )
    }
}
